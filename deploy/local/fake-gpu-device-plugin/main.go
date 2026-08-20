// Fake NVIDIA-shaped device plugin for local kind labs.
//
// Registers resource name nvidia.com/gpu (same string as the real plugin) so
// pod YAML matches what you will use on EKS. There is no CUDA, no driver, and
// no silicon — Allocate only returns empty env/mounts.
//
// Contract taught: kubelet device-plugin gRPC → node allocatable → scheduler.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	pluginapi "k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1"
)

const (
	resourceName = "nvidia.com/gpu"
	socketName   = "lab-fake-nvidia.sock"
)

func main() {
	gpus := flag.Int("gpus", 1, "fake GPUs to advertise on this node")
	flag.Parse()
	if *gpus < 1 {
		log.Fatal("-gpus must be >= 1")
	}

	pluginDir := os.Getenv("PLUGIN_DIR")
	if pluginDir == "" {
		pluginDir = pluginapi.DevicePluginPath
	}
	socketPath := filepath.Join(pluginDir, socketName)

	for {
		if err := runOnce(socketPath, *gpus); err != nil {
			log.Printf("plugin stopped: %v; restarting in 2s", err)
			time.Sleep(2 * time.Second)
			continue
		}
		// clean exit (e.g. kubelet restart signal path) — restart loop
		time.Sleep(2 * time.Second)
	}
}

func runOnce(socketPath string, gpus int) error {
	_ = os.Remove(socketPath)

	lis, err := net.Listen("unix", socketPath)
	if err != nil {
		return fmt.Errorf("listen %s: %w", socketPath, err)
	}
	defer func() {
		_ = lis.Close()
		_ = os.Remove(socketPath)
	}()

	srv := grpc.NewServer()
	plugin := &fakePlugin{gpus: gpus, socketPath: socketPath}
	pluginapi.RegisterDevicePluginServer(srv, plugin)

	errCh := make(chan error, 1)
	go func() {
		errCh <- srv.Serve(lis)
	}()

	if err := waitForSocket(socketPath, 10*time.Second); err != nil {
		srv.Stop()
		return err
	}
	if err := registerWithKubelet(socketPath); err != nil {
		srv.Stop()
		return fmt.Errorf("register: %w", err)
	}
	log.Printf("registered %s x%d via %s", resourceName, gpus, socketPath)

	return <-errCh
}

func waitForSocket(path string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("socket %s not ready", path)
}

func registerWithKubelet(pluginSocket string) error {
	conn, err := grpc.NewClient(
		"unix://"+pluginapi.KubeletSocket,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		return err
	}
	defer conn.Close()

	client := pluginapi.NewRegistrationClient(conn)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err = client.Register(ctx, &pluginapi.RegisterRequest{
		Version:      pluginapi.Version,
		Endpoint:     filepath.Base(pluginSocket),
		ResourceName: resourceName,
		Options: &pluginapi.DevicePluginOptions{
			PreStartRequired:                false,
			GetPreferredAllocationAvailable: false,
		},
	})
	return err
}

type fakePlugin struct {
	pluginapi.UnimplementedDevicePluginServer
	gpus       int
	socketPath string
}

func (p *fakePlugin) devices() []*pluginapi.Device {
	out := make([]*pluginapi.Device, 0, p.gpus)
	for i := 0; i < p.gpus; i++ {
		out = append(out, &pluginapi.Device{
			ID:     fmt.Sprintf("fake-gpu-%d", i),
			Health: pluginapi.Healthy,
		})
	}
	return out
}

func (p *fakePlugin) GetDevicePluginOptions(context.Context, *pluginapi.Empty) (*pluginapi.DevicePluginOptions, error) {
	return &pluginapi.DevicePluginOptions{}, nil
}

func (p *fakePlugin) ListAndWatch(_ *pluginapi.Empty, stream pluginapi.DevicePlugin_ListAndWatchServer) error {
	if err := stream.Send(&pluginapi.ListAndWatchResponse{Devices: p.devices()}); err != nil {
		return err
	}
	// Keep stream open; real plugins also push health updates here.
	<-stream.Context().Done()
	return stream.Context().Err()
}

func (p *fakePlugin) Allocate(_ context.Context, req *pluginapi.AllocateRequest) (*pluginapi.AllocateResponse, error) {
	resp := &pluginapi.AllocateResponse{}
	for _, container := range req.ContainerRequests {
		// Real NVIDIA plugin injects device nodes + env. We only acknowledge IDs.
		ids := strings.Join(container.DevicesIDs, ",")
		resp.ContainerResponses = append(resp.ContainerResponses, &pluginapi.ContainerAllocateResponse{
			Envs: map[string]string{
				"FAKE_NVIDIA_VISIBLE_DEVICES": ids,
				"LAB_FAKE_GPU":                "1",
			},
		})
	}
	return resp, nil
}

func (p *fakePlugin) GetPreferredAllocation(context.Context, *pluginapi.PreferredAllocationRequest) (*pluginapi.PreferredAllocationResponse, error) {
	return &pluginapi.PreferredAllocationResponse{}, nil
}

func (p *fakePlugin) PreStartContainer(context.Context, *pluginapi.PreStartContainerRequest) (*pluginapi.PreStartContainerResponse, error) {
	return &pluginapi.PreStartContainerResponse{}, nil
}

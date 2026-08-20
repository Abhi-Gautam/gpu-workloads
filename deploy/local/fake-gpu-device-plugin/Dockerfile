# Build for kind node arch (Docker Desktop on Apple Silicon → linux/arm64).
FROM golang:1.24-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
COPY main.go ./
RUN go mod download && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/fake-gpu-device-plugin .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/fake-gpu-device-plugin /fake-gpu-device-plugin
USER 0:0
ENTRYPOINT ["/fake-gpu-device-plugin"]

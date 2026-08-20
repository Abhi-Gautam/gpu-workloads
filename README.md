# GPU workloads

The orchestration engine already knows what a training-shaped operation is when a parent owns its shards, checkpoints are the only resume truth, and cancel means drain rather than abandon. What it does not yet know is how that operation meets real accelerators: gang scheduling, queues, preemption, placement, multi-GPU and eventually multi-cluster work.

That is the seam this lab is for. Temporal stays the control plane for the job as a business operation. A batch scheduler on real GPU Kubernetes owns who runs where and who yields. Checkpoints and artifacts stay out of History. Serverless GPU products can be a comparison later; they are not the place we learn scheduling.

The first cuts will be small enough to see gang block, fair queueing, and preempt-with-resume in the open. The direction is not one demo job — it is GPU work as something the same orchestration engine can submit, watch, cancel, and resume without building a satellite queue of its own.

These are experiments.

Local classroom (fake `nvidia.com/gpu` on kind — mechanisms only): `docs/local-kind-lab.md`.

# Build the manager binary
FROM public.ecr.aws/eks-distro-build-tooling/golang:1.20.4-5-gcc-al2 as builder
ARG TARGETOS
ARG TARGETARCH

# Env configuration
ENV GOPROXY=direct

WORKDIR /workspace

COPY . ./
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN go mod download

RUN make build-linux

# Vmlinux
FROM public.ecr.aws/amazonlinux/amazonlinux:2023 as vmlinuxbuilder
WORKDIR /vmlinuxbuilder
RUN yum update -y && \
    yum install -y iproute procps-ng && \
    yum install -y llvm clang make gcc && \
    yum install -y kernel-devel elfutils-libelf-devel zlib-devel libbpf-devel bpftool && \
    yum clean all
COPY . ./
RUN make vmlinuxh

# Build BPF
FROM public.ecr.aws/amazonlinux/amazonlinux:2 as bpfbuilder
WORKDIR /bpfbuilder
RUN yum update -y && \
    yum install -y iproute procps-ng && \
    yum install -y llvm clang make gcc && \
    yum install -y kernel-devel elfutils-libelf-devel zlib-devel libbpf-devel && \
    yum clean all

COPY . ./
COPY --from=vmlinuxbuilder /vmlinuxbuilder/pkg/ebpf/c/vmlinux.h ./pkg/ebpf/c/
RUN make build-bpf

FROM public.ecr.aws/eks-distro-build-tooling/eks-distro-base:latest.2
RUN yum update -y && \
    yum install -y iptables iproute jq && \
    yum install -y llvm clang make gcc && \
    yum install -y coreutils kernel-devel elfutils-libelf-devel zlib-devel libbpf-devel && \
    yum clean all

WORKDIR /
COPY --from=builder /workspace/controller .
COPY --from=builder /workspace/aws-eks-na-cli .
COPY --from=builder /workspace/aws-eks-na-cli-v6 .
COPY --from=bpfbuilder /bpfbuilder/pkg/ebpf/c/tc.v4ingress.bpf.o .
COPY --from=bpfbuilder /bpfbuilder/pkg/ebpf/c/tc.v4egress.bpf.o .
COPY --from=bpfbuilder /bpfbuilder/pkg/ebpf/c/tc.v6ingress.bpf.o .
COPY --from=bpfbuilder /bpfbuilder/pkg/ebpf/c/tc.v6egress.bpf.o .
COPY --from=bpfbuilder /bpfbuilder/pkg/ebpf/c/v4events.bpf.o .
COPY --from=bpfbuilder /bpfbuilder/pkg/ebpf/c/v6events.bpf.o .

ENTRYPOINT ["/controller"]

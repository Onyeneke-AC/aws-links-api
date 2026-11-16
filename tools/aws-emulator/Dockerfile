# AWS Emulator (AWS's local emulator of the AWS APIs) in a container, as its
# docs describe for macOS/Windows: AWS ships Linux packages, not an image.
# Used by `make emu-up`. Nothing here ever talks to a real AWS account.
#
# Not pinnable: AWS only publishes LTS/latest, so `make emu-up` prints the
# version that was installed (keep it with any evidence you capture).
FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal

ARG TARGETARCH
RUN case "$TARGETARCH" in arm64) a=aarch64 ;; amd64) a=x86_64 ;; *) echo "unsupported arch $TARGETARCH" >&2; exit 1 ;; esac \
    && curl -fsSL -o /tmp/aws-emulator.rpm "https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator-$a.rpm" \
    && rpm -i /tmp/aws-emulator.rpm && rm /tmp/aws-emulator.rpm

# The emulator writes its per-run keys, config and CA certificate under $HOME;
# `make emu-up` sets HOME to a folder it mounts from the repo (.emulator/).
EXPOSE 9297
ENTRYPOINT ["aws-emulator", "-b", "0.0.0.0", "--telemetry", "off"]

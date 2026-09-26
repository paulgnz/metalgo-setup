# The test image: Ubuntu 24.04 with what setup.sh needs to read and write a
# node's files, and systemd only for systemd-analyze verify. The fakes in
# /usr/local/sbin stand in for systemctl and ufw (there is no systemd running
# in a container), and for metalgo itself.
FROM ubuntu:24.04
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
      ca-certificates curl jq openssl perl systemd diffutils >/dev/null && rm -rf /var/lib/apt/lists/*
COPY fakes/systemctl fakes/ufw /usr/local/sbin/
COPY fakes/metalgo /usr/local/lib/fake-metalgo
RUN chmod 0755 /usr/local/sbin/systemctl /usr/local/sbin/ufw /usr/local/lib/fake-metalgo

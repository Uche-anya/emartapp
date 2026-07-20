#!/bin/bash

set -e

apt-get update -y

apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  git

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y

apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

usermod -aG docker ubuntu

systemctl enable docker
systemctl start docker

# Maven and the Angular build spike well past what the compose stack needs at
# rest. Swap keeps a build from OOM-killing the running containers.
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
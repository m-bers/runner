#!/bin/bash

set -x

echo "This will deploy a GitHub Actions self-hosted runner as an Ubuntu 20.04 virtual machine on an Ubuntu 20.04 KVM host. "

function check_packages {
  local packages=("$@")  # create an array of packages from arguments
  local to_install=()    # create an empty array to hold packages to install

  # loop over each package and check if it's installed
  for package in "${packages[@]}"; do
    if ! command -v "$package" > /dev/null 2>&1; then
      to_install+=("$package")  # add the package to the list of packages to install
    fi
  done

  # if any packages need to be installed, update package list and install them
  if [ ${#to_install[@]} -gt 0 ]; then
    sudo apt-get update > /dev/null 2>&1
    sudo apt-get install -y "${to_install[@]}" > /dev/null 2>&1
  else
    return 0  # return success if there are no packages to install
  fi
}

check_packages curl jq

if ! command -v gh > /dev/null 2>&1; then
  GHCLI_VERSION=$(curl -s https://api.github.com/repos/cli/cli/releases/latest | jq -r '.tag_name | ltrimstr("v")')
  curl -sL "https://github.com/cli/cli/releases/download/v${GHCLI_VERSION}/gh_${GHCLI_VERSION}_linux_amd64.tar.gz" | sudo tar -xz -C /usr/local/bin/ --strip-components=1 --transform="s|bin/gh|gh|" > /dev/null 2>&1
fi

cat ~/.gh_token | gh auth login --with-token
gh auth token > ~/.gh_token

RUNNER_TOKEN=$(gh api --method POST /repos/$1/actions/runners/registration-token | jq -r .token)
RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name | ltrimstr("v")')
VM_HOSTNAME="runner-$(uuidgen | cut -c1-8)"

check_packages \
  bridge-utils \
  cpu-checker \
  libvirt-daemon-system \
  libvirt-clients \
  libvirt-daemon \
  virtinst \
  qemu \
  qemu-kvm \
  uuid-runtime \
  genisoimage 

sudo systemctl enable --now libvirtd

# Get Ubuntu 20.04 Cloud image
wget -nc https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img

# # Set root password for debug
# sudo modprobe nbd max_part=63
# sudo qemu-nbd -c /dev/nbd0 focal-server-cloudimg-amd64.img
# sudo mount /dev/nbd0p1 /mnt
# echo "root:password" | sudo chroot /mnt chpasswd
# sudo umount /mnt
# sudo qemu-nbd -d /dev/nbd0
# sudo rmmod nbd

qemu-img create -f qcow2 -F qcow2 -o backing_file=focal-server-cloudimg-amd64.img -o size=20G $VM_HOSTNAME.qcow2

# Create user-data
cat << USER_DATA > user-data
#cloud-config
users:
  - name: runner
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
write_files:
  - path: /tmp/deploy.sh
    permissions: '0755'
    owner: runner:runner
    content: |
      #!/bin/bash
      mkdir actions-runner && cd actions-runner
      curl -o actions-runner-linux-x64-$RUNNER_VERSION.tar.gz \
        -L https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz
      tar xzf ./actions-runner-linux-x64-$RUNNER_VERSION.tar.gz
      ./config.sh --url https://github.com/$1 --token $RUNNER_TOKEN
      ./run.sh
runcmd:
  - sudo -i -u runner /tmp/deploy.sh
USER_DATA

# Create meta-data
cat << META_DATA > meta-data
instance-id: $VM_HOSTNAME
local-hostname: $VN_HOSTNAME
META_DATA

# Create cloud-init ISO
genisoimage -output user-data.iso -volid cidata -joliet -rock user-data meta-data

# Create VM from cloud image and cloud-init ISO
sudo virt-install \
  --name $VM_HOSTNAME \
  --os-variant ubuntu20.04 \
  --vcpus 6 \
  --ram 16384 \
  --network bridge=virbr0,model=virtio \
  --graphics vnc,listen=0.0.0.0 --noautoconsole \
  --disk path=$VM_HOSTNAME.qcow2,format=qcow2 \
  --disk path=user-data.iso,device=cdrom \
  --import

sudo rm meta-data user-data user-data.iso
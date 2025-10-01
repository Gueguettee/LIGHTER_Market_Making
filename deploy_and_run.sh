#!/bin/bash

# ---------- CONFIGURATION ----------
SSH_KEY_WINDOWS="/mnt/c/users/gaeta/.ssh/tokyo.pem"
SSH_KEY_MAC="~/.ssh/tokyo.pem"
SSH_USER="ubuntu"
REMOTE_DIR="/home/$SSH_USER/$(basename "$(pwd)")"
LOCAL_CODE_DIR="."
REMOTE_CODE_DIR="$REMOTE_DIR"
# DOCKER_IMAGE_NAME="lighter_market_making"
INSTANCE_FILE="$LOCAL_CODE_DIR/secrets/aws_instance.json"
CREDENTIALS_FILE="$LOCAL_CODE_DIR/secrets/aws_credentials.json"
# Files and directories to copy to the instance during installation
INSTALL_FILES=(".")
# Files and directories to copy to the instance before each run, everything except lighter_data:
EXECUTION_FILES=(".")
FILES_TO_RETRIEVE=("logs" "params" "lighter_data")
COMMAND_TO_RUN="docker compose up"
COMMAND_TO_START_RUN="docker compose up -d"
COMMAND_TO_STOP_RUN="docker compose down"
LOCAL_PACKAGES=(jq ssh rsync curl zip unzip dos2unix)
INSTANCE_PACKAGES=(jq dos2unix docker.io docker-compose docker-compose-v2 curl ssh zip unzip)
START_AND_STOP_INSTANCE=false
# -----------------------------------

set -e  # Exit on any error
shopt -s dotglob           # include hidden files in globs

SSH_KEY=$(eval echo "$SSH_KEY")
mkdir -p ~/.ssh
# If on Windows, copy the SSH key to WSL
if [[ "$(uname -r)" == *"Microsoft"* ]]; then
  SSH_KEY="$SSH_KEY_WINDOWS"
  cp "$SSH_KEY" ~/.ssh/ssh_key.pem -f
fi
# If on Mac, copy the SSH key to Linux subsystem
if [[ "$(uname)" == "Darwin" ]]; then
  SSH_KEY="$SSH_KEY_MAC"
  cp $SSH_KEY ~/.ssh/ssh_key.pem
fi
SSH_KEY=~/.ssh/ssh_key.pem
chmod 400 $SSH_KEY

configure_local() {
  sudo apt update && sudo apt upgrade -y

  # Check required packages
  for package in "${LOCAL_PACKAGES[@]}"; do
    if ! command -v $package &> /dev/null; then
      sudo apt install -y $package
    fi
  done

  sudo apt autoremove -y
}

# Configure AWS CLI from credentials JSON
configure_aws_cli() {
  if [ ! -f "$CREDENTIALS_FILE" ]; then
    echo "❌ Credentials file $CREDENTIALS_FILE not found."
    exit 1
  fi

  # If aws is not installed
  if ! command -v aws &> /dev/null; then
    # If x86_64 architecture
    if [[ "$(uname -m)" == "x86_64" ]]; then
        echo "⬇️ Installing AWS CLI for x86_64..."
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    else
        echo "⬇️ Installing AWS CLI for aarch64..."
        curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
    fi
    unzip awscliv2.zip
    sudo ./aws/install
    export PATH=/usr/local/bin:$PATH
  fi
  rm -rf awscliv2.zip aws

  AWS_ACCESS_KEY_ID=$(jq -r '.aws_access_key_id' "$CREDENTIALS_FILE")
  AWS_SECRET_ACCESS_KEY=$(jq -r '.aws_secret_access_key' "$CREDENTIALS_FILE")
  AWS_REGION=$(jq -r '.region' "$INSTANCE_FILE")

  if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" || -z "$AWS_REGION" ]]; then
    echo "❌ Incomplete AWS credentials in $CREDENTIALS_FILE."
    exit 1
  fi

  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
  aws configure set region "$AWS_REGION"
  echo "✅ AWS CLI configured with credentials."
}

# Read instance_id and instance_ip
if [ ! -f "$INSTANCE_FILE" ]; then
  echo "❌ Instance file $INSTANCE_FILE not found."
  exit 1
fi

INSTANCE_ID=$(jq -r '.instance_id' "$INSTANCE_FILE")

if [[ "$INSTANCE_ID" == "null" || -z "$INSTANCE_ID" ]]; then
  echo "❌ Invalid instance_id in $INSTANCE_FILE."
  exit 1
fi

# Start EC2 instance (wait until running)
start_instance() {
  if [ "$START_AND_STOP_INSTANCE" = true ]; then
    echo "🚀 Starting EC2 instance: $INSTANCE_ID"
    state=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].State.Name" --output text)
    if [ "$state" = "stopped" ]; then
        aws ec2 start-instances --instance-ids "$INSTANCE_ID"
    else
        echo "Instance already in state: $state"
    fi
    echo "⏳ Waiting for instance to be in 'running' state..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
  fi

  INSTANCE_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
  echo "IP publique: $INSTANCE_IP"

  # Put $INSTANCE_IP in known_hosts
  ssh-keyscan -v -H "$INSTANCE_IP" >> ~/.ssh/known_hosts
  if [[ "$INSTANCE_IP" == "null" || -z "$INSTANCE_IP" ]]; then
    echo "⚠️ instance_ip missing in $INSTANCE_FILE, script will try to retrieve IP after starting instance."
  fi
  echo "✅ Connection ssh successful."
}

# Stop EC2 instance (wait until stopped)
stop_instance() {
  if [ "$START_AND_STOP_INSTANCE" = false ]; then
    return
  fi
  echo "🛑 Stopping EC2 instance: $INSTANCE_ID"
  aws ec2 stop-instances --instance-ids "$INSTANCE_ID"
  echo "⏳ Waiting for instance to be stopped..."
  aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
  echo "✅ Instance stopped."
}

# Docker installation on the instance
install_instance() {
  echo "✅ Connecting to AWS instance: $INSTANCE_IP"
  ssh -ti "$SSH_KEY" "$SSH_USER@$INSTANCE_IP" << EOF
set -e

sudo apt update && sudo apt upgrade -y
for package in "${INSTANCE_PACKAGES[@]}"; do
  if ! command -v $package &> /dev/null; then
    echo "⬇️ Installing missing package: $package"
  fi
done

echo "🔍 Detecting system architecture..."
ARCH=\$(uname -m)
COMPOSE_DIR="\$HOME/.docker/cli-plugins"
COMPOSE_PLUGIN="\$COMPOSE_DIR/docker-compose"

mkdir -p "\$COMPOSE_DIR"

if [[ "\$ARCH" == "x86_64" ]]; then
    echo "✅ Detected architecture: x86_64"
    COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64"
elif [[ "\$ARCH" == "aarch64" ]]; then
    echo "✅ Detected architecture: aarch64 (ARM64)"
    COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64"
else
    echo "❌ Unsupported architecture: \$ARCH"
    exit 1
fi

echo "⬇️ Downloading Docker Compose V2 plugin from:"
echo "\$COMPOSE_URL"
curl -SL "\$COMPOSE_URL" -o "\$COMPOSE_PLUGIN"
chmod +x "\$COMPOSE_PLUGIN"

if docker compose version >/dev/null 2>&1; then
    echo "✅ Docker Compose V2 successfully installed (docker compose)"
else
    echo "⚠️ V2 plugin failed, fallback to docker-compose V1 via apt"
    sudo rm -f "\$COMPOSE_PLUGIN"
    sudo apt update
    sudo apt install -y docker-compose
fi

echo
if docker compose version >/dev/null 2>&1; then
    echo "🎉 You can use: docker compose"
    docker compose version
elif docker-compose version >/dev/null 2>&1; then
    echo "🎉 You can use: docker-compose"
    docker-compose version
else
    echo "❌ No working Docker Compose version installed."
    exit 1
fi

sudo systemctl enable docker
sudo systemctl start docker

sudo usermod -aG docker \$USER || true

sudo apt autoremove -y

mkdir -p "$REMOTE_DIR"
EOF

  echo "♻️ Rebooting instance to apply Docker group changes..."
  ssh -ti "$SSH_KEY" "$SSH_USER@$INSTANCE_IP" "sudo reboot"

  echo "⏳ Waiting for instance to reboot..."
  sleep 10
  aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"
  echo "✅ Instance rebooted and ready."

  echo "⏳ Waiting for SSH to come back..."
  while ! nc -zv "$INSTANCE_IP" 22 2>/dev/null; do
      sleep 5
  done

  echo "📤 Transfert du code vers l'instance..."
  if [ "${INSTALL_FILES[0]}" == "." ]; then
    INSTALL_FILES=($(ls -d "$LOCAL_CODE_DIR/"* | xargs -n 1 basename))
  fi
  ZIP_FILE="/tmp/code_transfer.zip"
  rm -f "$ZIP_FILE"
  zip -r "$ZIP_FILE" "${INSTALL_FILES[@]}"
  scp -i "$SSH_KEY" "$ZIP_FILE" "$SSH_USER@$INSTANCE_IP:$REMOTE_CODE_DIR/"
  ssh -i "$SSH_KEY" "$SSH_USER@$INSTANCE_IP" "unzip -o $REMOTE_CODE_DIR/$(basename $ZIP_FILE) -d $REMOTE_CODE_DIR && rm $REMOTE_CODE_DIR/$(basename $ZIP_FILE)"

  echo "🚀 Connexion pour build & run Docker..."
  ssh -ti "$SSH_KEY" "$SSH_USER@$INSTANCE_IP" << EOF
set -e

cd "$REMOTE_DIR"

echo "🛠️ Build de l'image Docker..."
docker compose build
EOF

    echo "✅ Installations done !"
}

# Run script on instance
run() {
  if [[ "$instruction" != "stopRun" ]]; then
    echo "📤 Transferring code to instance..."
  
    # if EXECUTION_FILES = (".") then retrieve everything
    if [ "${EXECUTION_FILES[0]}" == "." ]; then
      EXECUTION_FILES=($(ls -d "$LOCAL_CODE_DIR/"* | xargs -n 1 basename))
    fi

    ZIP_FILE="/tmp/code_transfer.zip"
    rm -f "$ZIP_FILE"
    zip -r "$ZIP_FILE" "${EXECUTION_FILES[@]}"
    scp -i "$SSH_KEY" "$ZIP_FILE" "$SSH_USER@$INSTANCE_IP:$REMOTE_CODE_DIR/"
    ssh -i "$SSH_KEY" "$SSH_USER@$INSTANCE_IP" "
chown $SSH_USER:$SSH_USER $REMOTE_CODE_DIR &&
sudo unzip -o $REMOTE_CODE_DIR/$(basename $ZIP_FILE) -d $REMOTE_CODE_DIR &&
sudo rm -f $REMOTE_CODE_DIR/$(basename $ZIP_FILE)
"
    rm -f "$ZIP_FILE"
  fi

  echo "🚀 Launch command on instance..."

  if [[ "$instruction" == "startRun" ]]; then
    ssh -i "$SSH_KEY" "$SSH_USER@$INSTANCE_IP" "
sudo timedatectl set-ntp true
cd \"$REMOTE_DIR\"
echo '🏁 Starting execution...'
$COMMAND_TO_START_RUN
"
  elif [[ "$instruction" == "stopRun" ]]; then
    ssh -i "$SSH_KEY" "$SSH_USER@$INSTANCE_IP" "
cd \"$REMOTE_DIR\"
echo '🛑 Stopping execution...'
$COMMAND_TO_STOP_RUN
"
  else
    ssh -i "$SSH_KEY" "$SSH_USER@$INSTANCE_IP" -t "
sudo timedatectl set-ntp true
cd \"$REMOTE_DIR\"
echo '🏁 Starting execution...'
$COMMAND_TO_RUN
"
  fi

  if [[ "$instruction" != "startRun" ]]; then
    echo "📥 Retrieving execution files..."

    # if file to retrieve = (".") then retrieve everything
    if [ "${FILES_TO_RETRIEVE[0]}" == "." ]; then
      FILES_TO_RETRIEVE=($(ssh -i "$SSH_KEY" "$SSH_USER@$INSTANCE_IP" "ls -d $REMOTE_CODE_DIR/* | xargs -n 1 basename"))
    fi

    ZIP_FILE="/tmp/retrieved_files.zip"
    rm -f "$ZIP_FILE"
    ssh -i "$SSH_KEY" "$SSH_USER@$INSTANCE_IP" "cd $REMOTE_CODE_DIR && zip -r /tmp/retrieved_files.zip ${FILES_TO_RETRIEVE[@]}"
    scp -i "$SSH_KEY" "$SSH_USER@$INSTANCE_IP:/tmp/retrieved_files.zip" "$ZIP_FILE"
    unzip -o "$ZIP_FILE" -d "$LOCAL_CODE_DIR/"
    rm -f "$ZIP_FILE"
  fi

  echo "✅ Done!"
}

# --------------------
# MAIN SCRIPT
# --------------------

instruction="$1"
if [[ "$instruction" == "install" ]]; then
  configure_local
  configure_aws_cli
  start_instance
  install_instance
  stop_instance
elif [[ "$instruction" == "connect" ]]; then
  start_instance
  ssh -ti "$SSH_KEY" "$SSH_USER@$INSTANCE_IP"
elif [[ "$instruction" == "run" ]]; then
  start_instance
  run
  stop_instance
elif [[ "$instruction" == "startRun" ]]; then
  start_instance
  run
elif [[ "$instruction" == "stopRun" ]]; then
  start_instance
  run
  stop_instance
else
  echo "Usage: $0 {install|connect|run|startRun|stopRun}"
fi

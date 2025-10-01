Param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("install","connect","run","startRun","stopRun")]
    [string]$Instruction
)

# ---------- CONFIGURATION ----------
$SSH_KEY          = "C:\Users\gaeta\.ssh\tokyo.pem"
$SSH_USER         = "ubuntu"
$LOCAL_CODE_DIR   = "."
$INSTANCE_FILE    = "$LOCAL_CODE_DIR\secrets\aws_instance.json"
$CREDENTIALS_FILE = "$LOCAL_CODE_DIR\secrets\aws_credentials.json"
$REMOTE_DIR       = "/home/$SSH_USER/$(Split-Path -Leaf (Get-Location))"
$REMOTE_CODE_DIR  = $REMOTE_DIR
$COMMAND_TO_RUN        = "docker compose up"
$COMMAND_TO_START_RUN  = "docker compose up -d"
$COMMAND_TO_STOP_RUN   = "docker compose down"
$INSTALL_FILES    = @(".")
$EXECUTION_FILES  = @(".")
$FILES_TO_RETRIEVE= @("logs","params","lighter_data")
$START_AND_STOP_INSTANCE = $false
$ErrorActionPreference = "Stop"
# -----------------------------------

function Configure-Local {
    Write-Host "⚙️ Installing local packages..."
    # On Windows: assume AWS CLI and jq installed manually
}

function Configure-AWSCLI {
    if (!(Test-Path $CREDENTIALS_FILE)) {
        Write-Error "❌ Missing $CREDENTIALS_FILE"
        exit 1
    }

    $creds = Get-Content $CREDENTIALS_FILE | ConvertFrom-Json
    $instance = Get-Content $INSTANCE_FILE | ConvertFrom-Json

    aws configure set aws_access_key_id $creds.aws_access_key_id
    aws configure set aws_secret_access_key $creds.aws_secret_access_key
    aws configure set region $instance.region
    Write-Host "✅ AWS CLI configured"
}

function Start-Instance {
    $instance = Get-Content $INSTANCE_FILE | ConvertFrom-Json
    $INSTANCE_ID = $instance.instance_id

    if ($START_AND_STOP_INSTANCE) {
        Write-Host "🚀 Starting instance $INSTANCE_ID"
        $state = aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].State.Name" --output text
        if ($state -eq "stopped") {
            aws ec2 start-instances --instance-ids $INSTANCE_ID | Out-Null
        }
        Write-Host "⏳ Waiting for instance..."
        aws ec2 wait instance-running --instance-ids $INSTANCE_ID
    }

    $global:INSTANCE_IP = aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].PublicIpAddress" --output text
    Write-Host "✅ Instance IP: $INSTANCE_IP"
}

function Stop-Instance {
    $instance = Get-Content $INSTANCE_FILE | ConvertFrom-Json
    $INSTANCE_ID = $instance.instance_id
    if ($START_AND_STOP_INSTANCE) {
        Write-Host "🛑 Stopping instance $INSTANCE_ID"
        aws ec2 stop-instances --instance-ids $INSTANCE_ID | Out-Null
        aws ec2 wait instance-stopped --instance-ids $INSTANCE_ID
        Write-Host "✅ Stopped"
    }
}

function Run-Remote {
    param([string]$Mode)

    # if ($Mode -ne "stopRun") {
    #     Write-Host "📤 Transferring code..."
    #     $zipFile = "$env:TEMP\code_transfer.zip"
    #     if (Test-Path $zipFile) { Remove-Item $zipFile -Force }
    #     Compress-Archive -Path $EXECUTION_FILES -DestinationPath $zipFile -Force
    #     scp -i $SSH_KEY $zipFile "${SSH_USER}@${INSTANCE_IP}:$REMOTE_CODE_DIR/"
    #     ssh -i $SSH_KEY "${SSH_USER}@${INSTANCE_IP}" 'unzip -o '"$REMOTE_CODE_DIR"'/$(Split-Path '"$zipFile"' -Leaf) -d '"$REMOTE_CODE_DIR"'; rm '"$REMOTE_CODE_DIR"'/$(Split-Path '"$zipFile"' -Leaf)'
    # }

   Write-Host "🚀 Launching code on instance..."

    if ($Mode -eq "startRun") {
        ssh -i $SSH_KEY "$SSH_USER@$INSTANCE_IP" "cd $REMOTE_DIR; $COMMAND_TO_START_RUN"
    }
    elseif ($Mode -eq "stopRun") {
        ssh -i $SSH_KEY "$SSH_USER@$INSTANCE_IP" "cd $REMOTE_DIR; $COMMAND_TO_STOP_RUN"
    }
    else {
        ssh -i $SSH_KEY -t "$SSH_USER@$INSTANCE_IP" "cd $REMOTE_DIR; $COMMAND_TO_RUN"
    }

    Write-Host "✅ Done"

    if ($Mode -ne "startRun") {
        Write-Host "📥 Retrieving files..."
        $zipFile = "$env:TEMP\retrieved_files.zip"
        $filesList = $FILES_TO_RETRIEVE -join ' '
        ssh -i $SSH_KEY "$SSH_USER@$INSTANCE_IP" "cd $REMOTE_CODE_DIR; zip -r /tmp/retrieved_files.zip $filesList"
        scp -i $SSH_KEY "${SSH_USER}@${INSTANCE_IP}:/tmp/retrieved_files.zip" $zipFile
        Expand-Archive $zipFile -DestinationPath $LOCAL_CODE_DIR -Force
        Remove-Item $zipFile
    }

    Write-Host "✅ Done"
}

# ---------------- MAIN ----------------
switch ($Instruction) {
    "install" {
        Configure-Local
        Configure-AWSCLI
        Start-Instance
        # InstallInstance would go here if you want the full docker setup
        Stop-Instance
    }
    "connect" {
        Start-Instance
        ssh -i $SSH_KEY "${SSH_USER}@${INSTANCE_IP}"
    }
    "run" {
        Start-Instance
        Run-Remote "run"
        Stop-Instance
    }
    "startRun" {
        Start-Instance
        Run-Remote "startRun"
    }
    "stopRun" {
        Start-Instance
        Run-Remote "stopRun"
        Stop-Instance
    }
}

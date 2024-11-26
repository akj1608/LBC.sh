#!/bin/bash

# Function to check if a command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: $1 is not installed. Please install it first."
        exit 1
    fi
}

# Function to check if policy exists
check_policy_exists() {
    local policy_name="$1"
    if aws iam get-policy --policy-arn "arn:aws:iam::$AWS_ACCOUNT_ID:policy/$policy_name" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to check if service account exists
check_service_account() {
    local namespace="$1"
    local name="$2"
    if kubectl get serviceaccount -n "$namespace" "$name" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check required commands
check_command "kubectl"
check_command "eksctl"
check_command "helm"
check_command "aws"
check_command "curl"

# Get AWS Account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo "Error: Could not get AWS Account ID. Please check AWS credentials."
    exit 1
fi

# Get input parameters
read -p "Enter your EKS cluster name: " CLUSTER_NAME
read -p "Enter your AWS region: " AWS_REGION
read -p "Enter your VPC ID: " VPC_ID

# Validate EKS cluster
if ! eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
    echo "Error: Cluster $CLUSTER_NAME not found in region $AWS_REGION"
    exit 1
fi

echo "Step 1: Downloading IAM policy..."
curl -o iam_policy_latest.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

echo "Step 2: Creating IAM policy if it doesn't exist..."
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
if check_policy_exists "$POLICY_NAME"; then
    echo "Policy $POLICY_NAME already exists"
    POLICY_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:policy/$POLICY_NAME"
else
    POLICY_ARN=$(aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file://iam_policy_latest.json \
        --query 'Policy.Arn' --output text)
    echo "Created policy: $POLICY_ARN"
fi

echo "Step 3: Creating IRSA for Load Balancer Controller..."
if check_service_account "kube-system" "aws-load-balancer-controller"; then
    echo "Service account already exists. Recreating..."
fi

eksctl create iamserviceaccount \
    --cluster="$CLUSTER_NAME" \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --attach-policy-arn="$POLICY_ARN" \
    --override-existing-serviceaccounts \
    --region="$AWS_REGION" \
    --approve

echo "Step 4: Adding and updating Helm repos..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update

echo "Step 5: Installing AWS Load Balancer Controller..."
# Check if controller is already installed
if helm list -n kube-system | grep -q "aws-load-balancer-controller"; then
    echo "Load Balancer Controller already installed. Upgrading..."
    HELM_CMD="upgrade"
else
    echo "Installing Load Balancer Controller..."
    HELM_CMD="upgrade --install"
fi

helm $HELM_CMD aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region="$AWS_REGION" \
    --set vpcId="$VPC_ID" \
    --set image.repository=602401143452.dkr.ecr."$AWS_REGION".amazonaws.com/amazon/aws-load-balancer-controller

echo "Verifying installation..."
kubectl get deployment -n kube-system aws-load-balancer-controller

echo "Installation complete!"

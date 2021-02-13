#!/bin/bash
export ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
export AWS_REGION=$(curl -s 169.254.169.254/latest/dynamic/instance-identity/document | grep region | cut -d\" -f4)

echo "export ACCOUNT_ID=${ACCOUNT_ID}" >> ~/.bash_profile
echo "export AWS_REGION=${AWS_REGION}" >> ~/.bash_profile
aws configure set default.region ${AWS_REGION}
aws configure get default.region

# create a folder for the scripts
mkdir ~/environment/scripts

# tools script
cat > ~/environment/scripts/install-tools <<-"EOF"

#!/bin/bash -ex

sudo yum install -y jq gettext bash-completion

sudo curl --silent --location "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" -o "session-manager-plugin.rpm"
sudo yum install -y session-manager-plugin.rpm

sudo curl --silent --location -o /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/v1.16.8/bin/linux/amd64/kubectl
sudo chmod +x /usr/local/bin/kubectl
echo 'source <(kubectl completion bash)' >>~/.bashrc
source ~/.bashrc

curl --silent --location "https://github.com/weaveworks/eksctl/releases/download/latest_release/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv -v /tmp/eksctl /usr/local/bin

if ! [ -x "$(command -v jq)" ] || ! [ -x "$(command -v envsubst)" ] || ! [ -x "$(command -v kubectl)" ] || ! [ -x "$(command -v eksctl)" ] || ! [ -x "$(command -v ssm-cli)" ]; then
  echo 'ERROR: tools not installed.' >&2
  exit 1
fi

pip install awscli --upgrade --user

EOF

chmod +x ~/environment/scripts/install-tools

~/environment/scripts/install-tools

# clone the github repositories
cd ~/environment
git clone https://github.com/brentley/ecsdemo-frontend.git
git clone https://github.com/brentley/ecsdemo-nodejs.git
git clone https://github.com/brentley/ecsdemo-crystal.git

cd ~/environment
curl -s https://raw.githubusercontent.com/brentley/appmeshworkshop/master/templates/appmesh-baseline.yml -o appmesh-baseline.yml

# Define environment variable
IAM_ROLE=$(curl -s 169.254.169.254/latest/meta-data/iam/info | \
  jq -r '.InstanceProfileArn' | cut -d'/' -f2)

#Check if the template is already deployed. If not, deploy it
CFN_TEMPLATE=$(aws cloudformation list-stacks | jq -c '.StackSummaries[].StackName | select( . == "appmesh-workshop" )')

if [ -z "$CFN_TEMPLATE" ]
then
  echo "Deploying Cloudformation Template"
  aws cloudformation deploy \
    --template-file appmesh-baseline.yml \
    --stack-name appmesh-workshop \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides Cloud9IAMRole=$IAM_ROLE
else
  echo "Template already deployed. Go ahead to the next chapter."
fi

# Retrieve private key
aws ssm get-parameter \
  --name /appmeshworkshop/keypair/id_rsa \
  --with-decryption | jq .Parameter.Value --raw-output > ~/.ssh/id_rsa

# Set appropriate permission on private key
chmod 600 ~/.ssh/id_rsa

# Store public key separately from private key
ssh-keygen -y -f ~/.ssh/id_rsa > ~/.ssh/id_rsa.pub


# bootstrap script
cat > ~/environment/scripts/bootstrap <<-"EOF"

#!/bin/bash -ex

echo 'Fetching CloudFormation outputs'
~/environment/scripts/fetch-outputs
echo 'Building Docker Containers'
~/environment/scripts/build-containers
echo 'Creating the ECS Services'
~/environment/scripts/create-ecs-service
echo 'Creating the EKS Cluster'
~/environment/scripts/build-eks

EOF

# fetch-outputs script
cat > ~/environment/scripts/fetch-outputs <<-"EOF"

#!/bin/bash -ex

STACK_NAME=appmesh-workshop
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" | \
jq -r '[.Stacks[0].Outputs[] | 
    {key: .OutputKey, value: .OutputValue}] | from_entries' > cfn-output.json

EOF

# Create EKS configuration file
cat > ~/environment/scripts/eks-configuration <<-"EOF"

#!/bin/bash -ex

STACK_NAME=appmesh-workshop
PRIVSUB1_ID=$(jq < cfn-output.json -r '.PrivateSubnetOne')
PRIVSUB1_AZ=$(aws ec2 describe-subnets --subnet-ids $PRIVSUB1_ID | jq -r '.Subnets[].AvailabilityZone')
PRIVSUB2_ID=$(jq < cfn-output.json -r '.PrivateSubnetTwo')
PRIVSUB2_AZ=$(aws ec2 describe-subnets --subnet-ids $PRIVSUB2_ID | jq -r '.Subnets[].AvailabilityZone')
PRIVSUB3_ID=$(jq < cfn-output.json -r '.PrivateSubnetThree')
PRIVSUB3_AZ=$(aws ec2 describe-subnets --subnet-ids $PRIVSUB3_ID | jq -r '.Subnets[].AvailabilityZone')
AWS_REGION=$(curl -s 169.254.169.254/latest/dynamic/instance-identity/document | grep region | cut -d\" -f4)

cat > /tmp/eks-configuration.yml <<-EKS_CONF
  apiVersion: eksctl.io/v1alpha5
  kind: ClusterConfig
  metadata:
    name: $STACK_NAME
    region: $AWS_REGION
  vpc:
    subnets:
      private:
        $PRIVSUB1_AZ: { id: $PRIVSUB1_ID }
        $PRIVSUB2_AZ: { id: $PRIVSUB2_ID }
        $PRIVSUB3_AZ: { id: $PRIVSUB3_ID }
  nodeGroups:
    - name: appmesh-workshop-ng
      labels: { role: workers }
      instanceType: m5.large
      desiredCapacity: 3
      ssh: 
        allow: false
      privateNetworking: true
      iam:
        withAddonPolicies:
          imageBuilder: true
          albIngress: true
          autoScaler: true
          appMesh: true
          xRay: true
          cloudWatch: true
          externalDNS: true
EKS_CONF

EOF

# Create the EKS building script
cat > ~/environment/scripts/build-eks <<-"EOF"

#!/bin/bash -ex

EKS_CLUSTER_NAME=$(jq < cfn-output.json -r '.EKSClusterName')

if [ -z "$EKS_CLUSTER_NAME" ] || [ "$EKS_CLUSTER_NAME" == null ]
then
  
  if ! aws sts get-caller-identity --query Arn | \
    grep -q 'assumed-role/AppMesh-Workshop-Admin/i-'
  then
    echo "Your role is not set correctly for this instance"
    exit 1
  fi

  sh -c ~/environment/scripts/eks-configuration
  eksctl create cluster -f /tmp/eks-configuration.yml
else

  NODES_IAM_ROLE=$(jq < cfn-output.json -r '.NodeInstanceRole')

  aws eks --region $AWS_REGION update-kubeconfig --name $EKS_CLUSTER_NAME
  cat > /tmp/aws-auth-cm.yml <<-EKS_AUTH
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: aws-auth
      namespace: kube-system
    data:
      mapRoles: |
        - rolearn: $NODES_IAM_ROLE 
          username: system:node:{{EC2PrivateDNSName}}
          groups:
            - system:bootstrappers
            - system:nodes
EKS_AUTH
  kubectl apply -f /tmp/aws-auth-cm.yml
fi

EOF

# build-containers script
cat > ~/environment/scripts/build-containers <<-"EOF"

#!/bin/bash -ex

CRYSTAL_ECR_REPO=$(jq < cfn-output.json -r '.CrystalEcrRepo')
NODEJS_ECR_REPO=$(jq < cfn-output.json -r '.NodeJSEcrRepo')

$(aws ecr get-login --no-include-email)

docker build -t crystal-service ecsdemo-crystal
docker tag crystal-service:latest $CRYSTAL_ECR_REPO:vanilla
docker push $CRYSTAL_ECR_REPO:vanilla

docker build -t nodejs-service ecsdemo-nodejs
docker tag nodejs-service:latest $NODEJS_ECR_REPO:latest
docker push $NODEJS_ECR_REPO:latest

EOF

# create-ecs-service script
cat > ~/environment/scripts/create-ecs-service <<-"EOF"

#!/bin/bash -ex

CLUSTER=$(jq < cfn-output.json -r '.EcsClusterName')
TASK_DEF=$(jq < cfn-output.json -r '.CrystalTaskDefinition')
TARGET_GROUP=$(jq < cfn-output.json -r '.CrystalTargetGroupArn')
SUBNET_ONE=$(jq < cfn-output.json -r '.PrivateSubnetOne')
SUBNET_TWO=$(jq < cfn-output.json -r '.PrivateSubnetTwo')
SUBNET_THREE=$(jq < cfn-output.json -r '.PrivateSubnetThree')
SECURITY_GROUP=$(jq < cfn-output.json -r '.ContainerSecurityGroup')

aws ecs create-service \
  --cluster $CLUSTER \
  --service-name crystal-service-lb \
  --task-definition $TASK_DEF \
  --load-balancer targetGroupArn=$TARGET_GROUP,containerName=crystal-service,containerPort=3000 \
  --desired-count 3 \
  --launch-type FARGATE \
  --network-configuration \
      "awsvpcConfiguration={
        subnets=[$SUBNET_ONE,$SUBNET_TWO,$SUBNET_THREE],
        securityGroups=[$SECURITY_GROUP],
        assignPublicIp=DISABLED}"

EOF

chmod +x ~/environment/scripts/*

~/environment/scripts/bootstrap

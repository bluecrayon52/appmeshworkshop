import boto3
import json
import time
from botocore.config import Config

my_config = Config(
    region_name = 'us-west-2',
    signature_version = 'v4',
    retries = {
        'max_attempts': 10,
        'mode': 'standard'
    }
)

cloud9 = boto3.client('cloud9', config=my_config)
ec2 = boto3.client('ec2', config=my_config)
iam = boto3.client('iam', config=my_config)
ssm = boto3.client('ssm', config=my_config)

ide_name = 'AppMesh-Workshop'
role_name = 'AppMesh-Workshop-Admin'
profile_name = 'AppMesh-Workshop-Admin'
managed_policy_arn = 'arn:aws:iam::aws:policy/AdministratorAccess'

assume_role_policy_doc = json.dumps({
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
})

# Create a Cloud9 environment
cloud9_create_response = cloud9.create_environment_ec2(
    name= ide_name,
    description='AppMesh Workshop IDE.',
    instanceType='t2.micro',
    tags=[
        {
            'Key': 'Env',
            'Value': 'AppMesh-Workshop-E'       ##TAG
        },
    ]
)

environmentId = cloud9_create_response['environmentId']
print(f"environmentId = {environmentId}")

# # Create an IAM role
create_role_response = iam.create_role(
    RoleName=role_name,
    AssumeRolePolicyDocument=assume_role_policy_doc
)
# print(create_role_response)

# # Attach a managed policy to the IAM role 
attach_role_response = iam.attach_role_policy(
    RoleName=role_name,
    PolicyArn=managed_policy_arn
)

# # Create an IAM instance profile
create_profile_response = iam.create_instance_profile(
    InstanceProfileName=profile_name
)

# # Associate IAM role with instance profile
add_role_response = iam.add_role_to_instance_profile(
    InstanceProfileName=profile_name,
    RoleName=role_name
)

time.sleep(30)

# Describe the underlying EC2 instance
ec2_describe_response = ec2.describe_instances(Filters=[{'Name': 'tag:Env','Values': ["AppMesh-Workshop-E"]}])     ##TAG

# print(ec2_describe_response)
instance_id = ec2_describe_response['Reservations'][0]['Instances'][0]['InstanceId']
instance_state = ec2_describe_response['Reservations'][0]['Instances'][0]['State']['Name']
print(f"instance_state = {instance_state}")
print(f"instance_id = {instance_id}")


# Wait for instance to be in a running state 
while instance_state == "pending":
    print("instance_state is pending")
    time.sleep(5)
    ec2_describe_response = ec2.describe_instances(Filters=[{'Name': 'tag:Env','Values': ["AppMesh-Workshop-E"]}])  ##TAG
    instance_state = ec2_describe_response['Reservations'][0]['Instances'][0]['State']['Name']

# # Associate IAM instance profile with EC2 instance
iam_profile_response = ec2.associate_iam_instance_profile(
    IamInstanceProfile={
        'Name': profile_name,
    },
    InstanceId=instance_id
)

describe_env_response = cloud9.describe_environments(environmentIds=[environmentId])
# print(json.dumps(describe_env_response, indent=2))
environment_state = describe_env_response['environments'][0]['lifecycle']['status']

# wait for cloud9 to be CREATED
while environment_state == "CREATING":
    print("environment_state is creating")
    time.sleep(5)
    describe_env_response = cloud9.describe_environments(environmentIds=[environmentId])
    environment_state = describe_env_response['environments'][0]['lifecycle']['status']

# # Run shell commands on Cloud9 instance
ssm_command_response = ssm.send_command(
    InstanceIds=[
        instance_id
    ],
    DocumentName='AWS-RunShellScript',
    Parameters={
        'workingDirectory': ['/home/ec2-user/environment'],
        'commands': [
            'curl -s https://raw.githubusercontent.com/bluecrayon52/appmeshworkshop/main/app_mesh.sh -o app_mesh.sh',
            'chmod +x app_mesh.sh',
            'sudo -u ec2-user ./app_mesh.sh'
        ]
    }
)

# print(ssm_command_response)


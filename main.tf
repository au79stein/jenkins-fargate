provider "aws" {
  region = "us-east-2"
}

# Fetch Latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["137112412989"]  # Amazon Linux 2023 AMI owner ID
}

#data "aws_vpc" "main" {
#  tags = {
#    Name = "main_vpc"  # Replace with your actual tag name
#  }
#}

# Lookup the VPC dynamically by its tag
#data "aws_vpc" "main_vpc" {
#  filter {
#    name   = "tag:Name"
#    values = ["main_vpc"]  # Replace with the tag that identifies your VPC
#  }
#}

#data "aws_subnet" "public_subnet" {
#  tags = {
#    Name = "public-subnet"  # Replace with the actual subnet tag name
#  }
#}

# Lookup the subnet dynamically based on its tag name and vpc_id
#data "aws_subnet" "public_subnet" {
#  filter {
#    name   = "tag:Name"
#    values = ["public-subnet"]  # Replace with your actual subnet name
#  }
#
#  vpc_id = data.aws_vpc.main_vpc.id  # Reference the dynamically fetched VPC ID
#}

# Define the VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "main_vpc"
  }
}

# Define the Public Subnet
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-2a"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet"
  }
}

# Define the Private Subnet
resource "aws_subnet" "private_subnet" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-2b"
  map_public_ip_on_launch = false

  tags = {
    Name = "private-subnet"
  }
}

# Not sure I need this right now
# Define a NAT Gateway (for outbound internet access from private subnet)
resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id

  tags = {
    Name = "NAT Gateway"
  }
}

# Define the Elastic IP for the NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

# Create Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "Main Internet Gateway"
  }
}

# Modify Public Subnet Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "Public Route Table"
  }
}

# Associate Route Table with Public Subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public.id
}

# Create Jenkins Security Group
resource "aws_security_group" "jenkins_sg" {
  #name_prefix = "jenkins-sg-"
  name = "jenkins-sg"
  description = "Allow SSH and HTTP(S) access"
  vpc_id      = aws_vpc.main.id
  #vpc_id      = data.aws_vpc.main.id  # Dynamically reference the VPC using the data source

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_service" "jenkins_agents" {
  name            = "jenkins-agent-service"
  cluster         = aws_ecs_cluster.jenkins_agents.id
  task_definition = aws_ecs_task_definition.jenkins_agent.arn
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public_subnet.id]  # Reference dynamically created subnet
    security_groups  = [aws_security_group.jenkins_sg.id]  # Reference dynamically created SG
    assign_public_ip = true
  }
}

# Create IAM Role for EC2 Instance with SSM Permissions
resource "aws_iam_role" "ec2_ssm_role" {
  name               = "ec2-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Attach AmazonSSMManagedInstanceCore Policy to IAM Role
resource "aws_iam_role_policy_attachment" "ssm_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.ec2_ssm_role.name
}

# Attach IAM Role Policy to Allow Attaching Other Policies (for automation)
resource "aws_iam_role_policy_attachment" "iam_attach_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  role       = aws_iam_role.ec2_ssm_role.name
}

# Create IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_ssm_instance_profile" {
  name = "ec2-ssm-instance-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

# Create Jenkins EC2 Instance with IAM Instance Profile
resource "aws_instance" "jenkins_master" {
  ami                   = data.aws_ami.amazon_linux_2023.id
  instance_type         = "t3.micro"
  #subnet_id             = data.aws_subnet.public_subnet.id  # Dynamically fetch the subnet ID
  subnet_id             = aws_subnet.public_subnet.id
  key_name              = "new-aws-deploy-key"
  iam_instance_profile  = aws_iam_instance_profile.ec2_ssm_instance_profile.name
  vpc_security_group_ids = [aws_security_group.jenkins_sg.id]

  root_block_device {
    volume_size = 20
  }


  user_data = <<-EOF
              #!/bin/bash
              set -x
              sudo yum update -y
              sudo yum install -y wget java-17-amazon-corretto-devel

              # SSM Agent
              # SSM Agent
              # SSM Agent
              sudo yum install -y amazon-ssm-agent
              sudo systemctl start amazon-ssm-agent
              sudo systemctl enable amazon-ssm-agent

              # Install Session Manager Plugin
              # Install Session Manager Plugin
              # Install Session Manager Plugin
              sudo dnf install -y https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm

              # Install AWS CLI (if not installed)
              sudo yum install -y aws-cli

              # Install Jenkins
              # Install Jenkins
              # Install Jenkins
              sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat/jenkins.repo
              sudo rpm --import https://pkg.jenkins.io/redhat/jenkins.io.key
              sudo yum --nogpgcheck install -y jenkins

              # Jenkins Override Unlock Screen
              # Jenkins Override Unlock Screen
              # Jenkins Override Unlock Screen
              mkdir -p /etc/systemd/system/jenkins.service.d
              cat <<EOC > /etc/systemd/system/jenkins.service.d/override.conf
              [Service]
              Environment="JAVA_OPTS=-Djenkins.install.runSetupWizard=false"
              EOC

              # Reload systemd to apply change
              systemctl daemon-reload
              systemctl enable jenkins

              # prepare list of plugins before jenkins starts for the very first time
              # Prepare the plugin list BEFORE Jenkins starts
              cat <<EOP > /var/lib/jenkins/plugins.txt
              amazon-ecs
              ec2
              git
              pipeline
              credentials
              workflow-aggregator
              job-dsl
              blueocean
              EOP

              # Ensure correct ownership
              chown -R jenkins:jenkins /var/lib/jenkins/

              systemctl start jenkins

              # Wait for Jenkins to be ready
              sleep 90

              # Wait for Jenkins to be fully up before installing plugins
              JENKINS_URL="http://localhost:8080/"
              until curl -s --head --fail $JENKINS_URL; do
                  sleep 10
              done


              # Capture initial Jenkins admin password
              JENKINS_PASSWORD_FILE="/var/lib/jenkins/secrets/initialAdminPassword"
              ADMIN_PASSWORD=$(sudo cat "$JENKINS_PASSWORD_FILE")
              sudo cat $JENKINS_PASSWORD_FILE > /home/ec2-user/jenkins-admin-password


              # Store Jenkins password in AWS SSM (overwrite if exists)
              INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
              aws ssm put-parameter --name "/jenkins/admin-password" --value "$ADMIN_PASSWORD" --type "SecureString" --overwrite --region us-east-2


              # download jenkins cli from this local jenkins master
              mkdir -p /usr/local/bin/jenkins/
              chmod 755 /usr/local/bin/jenkins/
              wget -O /usr/local/bin/jenkins/jenkins-cli.jar "$JENKINS_URL/jnlpJars/jenkins-cli.jar"

              # Create the Jenkins admin user securely
              java -jar /usr/local/bin/jenkins/jenkins-cli.jar -s $JENKINS_URL groovy = <<EOA
              import jenkins.model.*
              import hudson.security.*
              def instance = Jenkins.getInstance()
              def hudsonRealm = new HudsonPrivateSecurityRealm(false)
              def user = hudsonRealm.createAccount("admin", "Jenkins-1-Secure-Password!")
              user.save()
              instance.setSecurityRealm(hudsonRealm)
              instance.save()
              EOA

              # Install plugins from plugins.txt
              #sudo -u jenkins java -jar /usr/share/jenkins/jenkins-cli.jar -s $JENKINS_URL install-plugin $(tr '\n' ' ' < /var/lib/jenkins/plugins.txt)
              sudo -u jenkins java -jar /usr/local/bin/jenkins/jenkins-cli.jar -s $JENKINS_URL install-plugin $(tr '\n' ' ' < /var/lib/jenkins/plugins.txt)

              # restart jenkins to activate pluglins
              systemctl restart jenkins

              set +x
              EOF

  tags = {
    Name = "Jenkins Master"
  }

  depends_on = [aws_security_group.jenkins_sg, aws_internet_gateway.main]
}

# Allocate Elastic IP for Jenkins
resource "aws_eip" "jenkins_eip" {
  instance = aws_instance.jenkins_master.id
}

# doesn't seem to be working correctly, not being mounte
# troubleshoot later just bumped up root fs to 20GB for now
# Create Additional EBS Volume
#resource "aws_ebs_volume" "additional_volume" {
#  availability_zone = aws_instance.jenkins_master.availability_zone
#  size              = 8
#  type              = "gp2"
#}
#
## Attach Additional EBS Volume
#resource "aws_volume_attachment" "attach_volume" {
#  device_name = "/dev/sdf"
#  volume_id   = aws_ebs_volume.additional_volume.id
#  instance_id = aws_instance.jenkins_master.id
#}

# Create ECS Cluster for Jenkins Agents
resource "aws_ecs_cluster" "jenkins_agents" {
  name = "jenkins-ecs-cluster"
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy_attachment" "ecs_task_execution_role_policy" {
  name       = "ecs-task-execution-role-policy"
  roles      = [aws_iam_role.ecs_task_execution_role.name]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "jenkins_agent" {
  family                   = "jenkins-agent"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "jenkins-agent"
      image     = "jenkins/inbound-agent:latest"
      essential = true
      environment = [
        { "name": "JENKINS_URL", "value": "http://${aws_eip.jenkins_eip.public_ip}:8080" }

      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = "/ecs/jenkins-agent"
          awslogs-region        = "us-east-2"
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

# Output Jenkins URL
output "jenkins_url" {
  value = "http://${aws_instance.jenkins_master.public_ip}:8080"
}

# Output ECS Cluster ARN
output "ecs_cluster_arn" {
  value = aws_ecs_cluster.jenkins_agents.arn
}

output "jenkins_eip" {
  value = aws_eip.jenkins_eip.public_ip

}


terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

## Provider Configuration
provider "aws" {
  region     = "us-east-1"
}

provider "random" {
}
##

## My current region
data "aws_region" "current" {
}

## VPC
resource "aws_vpc" "hpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

### Subnets within this VPC
resource "aws_subnet" "a" {
  vpc_id                  = aws_vpc.hpc.id
  availability_zone       = "${data.aws_region.current.name}a"
  map_public_ip_on_launch = true
  cidr_block              = "10.0.1.0/24"
}

resource "aws_subnet" "b" {
  vpc_id                  = aws_vpc.hpc.id
  availability_zone       = "${data.aws_region.current.name}b"
  map_public_ip_on_launch = true
  cidr_block              = "10.0.2.0/24"
}
###

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.hpc.id
}

### Routes within that VPC
resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.hpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "rt_a" {
  subnet_id      = aws_subnet.a.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_route_table_association" "rt_b" {
  subnet_id      = aws_subnet.b.id
  route_table_id = aws_route_table.rt.id
}
###

## Controller Instance configuration
### Key Pair to use
resource "aws_key_pair" "keypair" {
  key_name   = "tf_keypair"
  public_key = file("my-key-pair.pub")
}

data "aws_ami" "centos" {
  most_recent = true
  owners = [ "125523088429" ] # Centos
  filter {
    name = "image-id"
    values = ["ami-00e87074e52e6c9f9"]
  }
}
    

### The controller VM
resource "aws_instance" "controller" {
  ami                         = data.aws_ami.centos.id
  subnet_id                   = aws_subnet.a.id
  instance_type               = "t2.micro"
  key_name                    = aws_key_pair.keypair.id
  vpc_security_group_ids      = [aws_security_group.controller_ssh.id]
  associate_public_ip_address = true
  root_block_device {
    volume_type           = "gp2"
    delete_on_termination = "true"
    volume_size           = "20"
  }
  tags = {
    Name = "controller"
  }
  user_data = <<-EOF
#cloud-config
yum_repos:
  ensiie:
    baseurl: https://tps.delhomme.org/repo/
    gpgcheck: false
    enabled: true
    name: "Slurm repo"

packages:
  - slurm-slurmctld
  - slurm-slurmd
  - munge
  
bootcmd:
  - mkdir -p /etc/slurm/slurm.conf.d/
  - yum install -y epel-release

runcmd:
  - mkdir /var/spool/slurm 
  - 'chown -R munge:munge /etc/munge'
  - chmod 0600 /etc/munge/munge.key
  - systemctl start munge

write_files:
  - path: '/etc/munge/munge.key'
    content: "${random_password.munge_key.result}"

  - path: '/etc/slurm/slurm.conf'
    permissions: '0644'
    content: |
      #
      ClusterName=amazon
      ControlMachine=%NAME%
      ControlAddr=%IP%
      
      SlurmdUser=root
      SlurmctldPort=6817
      SlurmdPort=6818
      AuthType=auth/munge
      
      StateSaveLocation=/var/spool/slurm/ctld
      SlurmdSpoolDir=/var/spool/slurm/d
      SwitchType=switch/none
      MpiDefault=none
      SlurmctldPidFile=/var/run/slurmctld.pid
      SlurmdPidFile=/var/run/slurmd.pid
      ProctrackType=proctrack/pgid
      
      ReturnToService=2

      # TIMERS
      SlurmctldTimeout=300
      SlurmdTimeout=60
      InactiveLimit=0
      MinJobAge=300
      KillWait=30
      Waittime=0
      #
      # SCHEDULING
      SchedulerType=sched/backfill
      SelectType=select/cons_res
      SelectTypeParameters=CR_Core
      FastSchedule=1
      # LOGGING
      SlurmctldDebug=3
      SlurmctldLogFile=/var/log/slurmctld.log
      SlurmdDebug=3
      SlurmdLogFile=/var/log/slurmd.log
      DebugFlags=NO_CONF_HASH
      JobCompType=jobcomp/none

      SuspendTime=60
      ResumeTimeout=500
      TreeWidth=60000
      SuspendExcNodes=%NAME%
      ResumeRate=0
      SuspendRate=0
     
      #SuspendProgram=/usr/bin/compute_stop.sh
      #ResumeProgram=/usr/bin/compute_start.sh
      
      include slurm.conf.d/slurm_nodes.conf
      
      PartitionName=all Nodes=ALL Default=YES MaxTime=INFINITE State=UP


  - path: '/etc/slurm/slurm.conf.d/slurm_nodes.conf'
    permissions: '0644'
    content: |
      NodeName=%NAME%
EOF


  provisioner "remote-exec" {
    inline = [
      "while ! sudo grep 'Cloud-init .* finished' /var/log/cloud-init.log; do echo Waiting for cloud-init to finish && sleep 2; done",
      "sudo sed -i -e 's/%NAME%/${self.private_dns}/' -e 's/%IP%/${self.private_ip}/' /etc/slurm/slurm.conf /etc/slurm/slurm.conf.d/*",
      "sudo systemctl start slurmctld slurmd",
    ]

    connection {
      type        = "ssh"
      user        = "centos"
      private_key = file("my-key-pair")
      host        = self.public_dns
    }
  }
}

### Flows to authorize from the internet and between nodes of the VPC
resource "aws_security_group" "controller_ssh" {
  vpc_id = aws_vpc.hpc.id
  ingress {
    from_port   = 22
    to_port     = 22
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

### A random string used as the munge key
resource "random_password" "munge_key" {
  length  = 4096
  special = true
}
##

## Tell terraform to output the public IP of the controller so we can ssh.
output "controller_ip" {
  value = "ssh -i my-key-pair centos@${aws_instance.controller.public_ip}"
}


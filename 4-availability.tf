resource "aws_subnet" "comp_a" {
  vpc_id                  = aws_vpc.hpc.id
  availability_zone       = "${data.aws_region.current.name}a"
  map_public_ip_on_launch = true
  cidr_block              = "10.0.10.0/24"
}

resource "aws_subnet" "comp_b" {
  vpc_id                  = aws_vpc.hpc.id
  availability_zone       = "${data.aws_region.current.name}b"
  map_public_ip_on_launch = true
  cidr_block              = "10.0.11.0/24"
}

resource "aws_subnet" "comp_c" {
  vpc_id                  = aws_vpc.hpc.id
  availability_zone       = "${data.aws_region.current.name}c"
  map_public_ip_on_launch = true
  cidr_block              = "10.0.12.0/24"
}

resource "aws_route_table_association" "rt_comp_a" {
  subnet_id      = aws_subnet.comp_a.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_route_table_association" "rt_comp_b" {
  subnet_id      = aws_subnet.comp_b.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_route_table_association" "rt_comp_c" {
  subnet_id      = aws_subnet.comp_c.id
  route_table_id = aws_route_table.rt.id
}

# Compute user-data template
locals {
  compute_user_data_2 = <<-EOF
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
  - python-pip

bootcmd:
  - mkdir -p /etc/slurm/slurm.conf.d/
  - yum install -y epel-release

runcmd:
  - pip install awscli
  - mkdir /var/spool/slurm
  - 'chown -R munge:munge /etc/munge'
  - chmod 0600 /etc/munge/munge.key
  - systemctl start munge
  - NAME=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$(curl -sf http://169.254.169.254/latest/meta-data/instance-id)" --region ${data.aws_region.current.name} | grep -2 Name | grep Value | tr -d ' ' | cut -f2 -d':' | tr -d '"' | tr -d ',')
  - echo "SLURMD_OPTIONS='-N $NAME'" > /etc/sysconfig/slurmd
  - scontrol update nodename=$NAME nodehostname=$(hostname -f) nodeaddr=$(hostname -i)
  - systemctl start slurmd

write_files:
  - path: '/etc/munge/munge.key'
    content: "${random_password.munge_key.result}"

  - path: '/etc/slurm/slurm.conf'
    permissions: '0644'
    content: |
      #
      ClusterName=amazon
      ControlMachine=${aws_instance.controller.private_dns}
      ControlAddr=${aws_instance.controller.private_ip}

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
      SuspendExcNodes=${aws_instance.controller.private_dns}
      ResumeRate=0
      SuspendRate=0

      #SuspendProgram=/usr/bin/compute_stop.sh
      #ResumeProgram=/usr/bin/compute_start.sh

      include slurm.conf.d/slurm_nodes.conf

      PartitionName=all Nodes=ALL Default=YES MaxTime=INFINITE State=UP


  - path: '/etc/slurm/slurm.conf.d/slurm_nodes.conf'
    permissions: '0644'
    content: |
      NodeName=${aws_instance.controller.private_dns}
      NodeName=compute-a-[1-100] Features=${aws_subnet.comp_a.id} State=Cloud
      NodeName=compute-b-[1-100] Features=${aws_subnet.comp_b.id} State=Cloud
      NodeName=compute-c-[1-100] Features=${aws_subnet.comp_c.id} State=Cloud
EOF
}

## The effective compute template

resource "aws_launch_template" "compute_a" {
  name          = "slurm_compute_a"
  image_id      = data.aws_ami.centos.id
  instance_type = "t2.micro"
  key_name      = aws_key_pair.keypair.id
  iam_instance_profile {
    name = aws_iam_instance_profile.compute.id
  }
  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    subnet_id                   = aws_subnet.comp_a.id
    security_groups             = [aws_security_group.controller_ssh.id]
  }
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 20
      delete_on_termination = true
    }
  }
  user_data = base64encode(local.compute_user_data_2)
}

resource "aws_launch_template" "compute_b" {
  name          = "slurm_compute_b"
  image_id      = data.aws_ami.centos.id
  instance_type = "t2.micro"
  key_name      = aws_key_pair.keypair.id
  iam_instance_profile {
    name = aws_iam_instance_profile.compute.id
  }
  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    subnet_id                   = aws_subnet.comp_b.id
    security_groups             = [aws_security_group.controller_ssh.id]
  }
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 20
      delete_on_termination = true
    }
  }
  user_data = base64encode(local.compute_user_data_2)
}

resource "aws_launch_template" "compute_c" {
  name          = "slurm_compute_c"
  image_id      = data.aws_ami.centos.id
  instance_type = "t2.micro"
  key_name      = aws_key_pair.keypair.id
  iam_instance_profile {
    name = aws_iam_instance_profile.compute.id
  }
  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    subnet_id                   = aws_subnet.comp_c.id
    security_groups             = [aws_security_group.controller_ssh.id]
  }
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 20
      delete_on_termination = true
    }
  }
  user_data = base64encode(local.compute_user_data_2)
}

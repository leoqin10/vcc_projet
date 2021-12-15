# Compute user-data template
locals {
  compute_user_data = <<-EOF
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
  - unzip
  
bootcmd:
  - mkdir -p /etc/slurm/slurm.conf.d/
  - yum install -y epel-release

runcmd:
  - curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  - unzip awscliv2.zip
  - ./aws/install
  - mkdir -p /var/spool/slurm 
  - 'chown -R munge:munge /etc/munge'
  - chmod 0600 /etc/munge/munge.key
  - systemctl start munge
  - NAME=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$(curl -sf http://169.254.169.254/latest/meta-data/instance-id)" --region ${data.aws_region.current.name} | grep -A4 Name | grep Value | tr -d ' ' | cut -f2 -d':' | tr -d '"' | tr -d ',')
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
      NodeName=compute[1-100] State=Cloud
EOF

}

## The effective compute template

resource "aws_launch_template" "compute" {
  name          = "slurm_compute"
  image_id      = data.aws_ami.centos.id
  instance_type = "t2.micro"
  key_name      = aws_key_pair.keypair.id
  iam_instance_profile {
    name = aws_iam_instance_profile.compute.id
  }
  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    subnet_id                   = aws_subnet.a.id
    security_groups             = [aws_security_group.controller_ssh.id]
  }
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 20
      delete_on_termination = true
    }
  }
  user_data = base64encode(local.compute_user_data)
}

##
resource "aws_iam_instance_profile" "compute" {
  role = aws_iam_role.compute.name
}

data "aws_iam_policy_document" "compute_assumed_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "compute" {
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.compute_assumed_role.json
}

data "aws_iam_policy_document" "ec2_tags" {
  statement {
    actions   = ["ec2:DescribeTags"]
    effect    = "Allow"
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "compute_ec2" {
  role   = aws_iam_role.compute.id
  policy = data.aws_iam_policy_document.ec2_tags.json
}


# IAM profile which allow controller to access ec2 and iam API

resource "aws_iam_instance_profile" "controller" {
  role = aws_iam_role.controller.name
}

data "aws_iam_policy_document" "controller_assumed_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "controller" {
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.controller_assumed_role.json
}

data "aws_iam_policy_document" "ec2" {
  statement {
    actions   = ["ec2:*"]
    effect    = "Allow"
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "controller_ec2" {
  role   = aws_iam_role.controller.id
  policy = data.aws_iam_policy_document.ec2.json
}

data "aws_iam_policy_document" "iam" {
  statement {
    actions   = ["iam:*"]
    effect    = "Allow"
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "controller_iam" {
  role   = aws_iam_role.controller.id
  policy = data.aws_iam_policy_document.iam.json
}


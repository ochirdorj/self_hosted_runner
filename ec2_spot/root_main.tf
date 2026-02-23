module "self_hosted" {
  source = "./modules"

#Input variables
image_id = "ami-05563ed679ef6325d"
instance_type = ["t3.medium", "c5.large", "c6i.large"]
tags = {
  "Environment": "dev"
  "Managed_By" : "terraform"
  "Project": "project-13"
  "Team": "ap13"
  "Owner": "eenkhchuluun"
}
Environment = "shs"
Managed_by = "terraform"
Project = "ap13"
Team = "DevOps"
Owner = "eenkhchuluun"
root_volume_size = 20
vpc_id = "vpc-0918c0d670058725e"
lambda_subnets = [
  "subnet-0e82222f8b004da60",
  "subnet-0eb6d8b023a990885"
]
region = "us-east-1"
github_app_credentials_secret_name = "github-actions-app-credentials"
github_owner = "aKumoProject-13"
runner_labels = "self-hosted,linux,x64"
launch_template = "github-runner-lt"
create_spot_role = false
}




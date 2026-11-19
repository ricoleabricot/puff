# Source me in every new terminal:  source env.sh
# Points the AWS CLI at Floci (your local AWS), never at a real AWS account.
unset AWS_PROFILE
export AWS_ENDPOINT_URL='http://localhost.floci.io:4566'
export AWS_ACCESS_KEY_ID='test' AWS_SECRET_ACCESS_KEY='test'
export AWS_DEFAULT_REGION='us-east-1' AWS_PAGER=''
# Floci's container registry. Push here, use it as the image in ECS.
export REGISTRY='localhost:5100'
# EC2 images and types follow your machine (Apple Silicon = arm64)
case "$(uname -m)" in
  arm64|aarch64) export AMI='ami-amazonlinux2023-arm64' TYPE='t4g.micro' ;;
  *)             export AMI='ami-0abcdef1234567891'      TYPE='t3.micro'  ;;
esac
echo "Floci env ready: $AWS_ENDPOINT_URL, region $AWS_DEFAULT_REGION, EC2 $TYPE"

# Quest AWS MVP

## Intro

This repository contains everything needed to run ReArc Quest as an MVP with a local deployment pipeline and AWS Cloud deployment.

## Basics
Three CloudFormation stacks running on one **t3.micro**

`quest-net` ALB spanning two public subnets

`quest-ecr` Hosted Docker images built locally

`quest-app` EC2 instance running Docker 

HTTPS with a **self-signed certificate is mandatory** for cloud deployment

Base OS used is Amazon Linux 2023 `2023.12.20261029.0`

AMI is pinned to `ami-073f45061d35c86f0` in **us-east-1**

## Current Architecture
The deployment runs in AWS us-east-1. The local deploy creates three CloudFormation stacks and builds and pushes the container image. quest-net supplies the VPC and two public subnets. quest-ecr owns the image repository. quest-app owns the ALB, EC2 instance, and IAM resources.
Public clients reach the ALB over HTTPS on port 443. The ALB forwards HTTP traffic to the Node.js container on port 3000, running on one t3.micro instance. ACM supplies the imported self-signed certificate, and SSM Parameter Store supplies the quest word at instance startup.

![Current AWS deployment architecture](./Docs/AWS-Arch.drawio.png)


## Local Requirements
- *nix/macOS
- AWS CLI 
- Docker with Buildx, Bash, Python 3, curl, and OpenSSL supporting `-addext`.

## Deploy

Run from the repository root in Bash:

```bash
bash scripts/deploy.sh
```

All deployment logic lives in `scripts/deploy.sh`

- Bootstraps the Network stack
- Bootstraps the ECR stack
- Builds and pushes Dockerfile output image as `latest` 
- Deploys the app stack 


Deploy command uses `CERTIFICATE_ARN` if
exists. Otherwise it reuses the ARN from the existing app stack, and generates/imports a `quest.local` certificate. If needed, `deploy.sh` generates a 365-day RSA self-signed
certificate, imports it into ACM, and removes its temporary certificate and
private key.

## Set the quest word

This stores the word as the SSM Parameter Store **SecureString**
`/$STACK_PREFIX/secret-word` using the default AWS-managed SSM key, then
replaces the instance with `UseSecret=true`. 

The instance retrieves it at startup into a root-readable environment file
and passes `SECRET_WORD` into Docker. 

Secret values are passed to AWS in a CHMOD 600 temporary JSON file that is
removed on exit, including on failure.


## Local Docker Build/Run

```bash
docker build --platform linux/amd64 -t quest:local .

docker run --rm --platform linux/amd64 -p 127.0.0.1:3000:3000 --name quest-local quest:local

curl http://localhost:3000/health_check
```

Local Docker serves HTTP only. 

HTTPS applies to the AWS deployment.

A health check endpoint to the Express app was added. `health_check/`

## Verification 

The script below will exercise and call the existing deployment. Adjust the BASE_URL within the script below to modify endpoint. 

For screenshot verification, see [Docker](docs/proof/docker.png), [index](docs/proof/index.png), [load-balanced](docs/proof/loadbalanced.png), [secret word](docs/proof/secret_word.png), and [TLS](docs/proof/tls.png).

```
bash scripts/test-endpoints.sh
```

### Example Output

```
mhiggins@MacBookPro ~/projects/quest (master) $ ./scripts/test-endpoints.sh 

Testing endpoints against: https://quest--loadb-klcwbnvj2sl2-194158873.us-east-1.elb.amazonaws.com
URL: https://quest--loadb-klcwbnvj2sl2-194158873.us-east-1.elb.amazonaws.com/
The secret word is CONTAIN

URL: https://quest--loadb-klcwbnvj2sl2-194158873.us-east-1.elb.amazonaws.com/docker
Congratulations! You are running in a Docker container

URL: https://quest--loadb-klcwbnvj2sl2-194158873.us-east-1.elb.amazonaws.com/secret_word
Congratulations. Secret word is: NostraCulpa (exceptional)

URL: https://quest--loadb-klcwbnvj2sl2-194158873.us-east-1.elb.amazonaws.com/loadbalanced
Congratulations! Looks like you successfully configured an AWS load balancer

URL: https://quest--loadb-klcwbnvj2sl2-194158873.us-east-1.elb.amazonaws.com/tls
Congratulations! Looks like you successfully configured TLS (https)```

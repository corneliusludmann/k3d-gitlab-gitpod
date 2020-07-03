# [GitLab](https://gitlab.com) and [Gitpod](https://gitpod.io) installation on [k3d](https://k3d.io/)

This repository provides you with an example how to install the combination of [GitLab](https://gitlab.com) 13.0.5 as Git hoster and [Gitpod](https://gitpod.io) 0.4.0 as one-click development environment (browser IDE) with [k3d](https://k3d.io/).

## Prerequisites

You need to have the following tools installed:
- bash
- docker
- [k3d](https://k3d.io/#installation) v3.0.0 or newer
- kubectl
- helm

Additionally, you need domains pointing to your server and a wildcard SSL certificate.

### DNS config and SSL certificate
Assuming you domain is `dev.example.com`, every subdomain should resovle to your server. If you have [dnsmasq](http://www.thekelleys.org.uk/dnsmasq/doc.html) running as DNS server you can simple add the following line to your dnsmasq configuration (replace your server domain and server IP):
```
address=/dev.example.com/10.0.0.75
```


You need a SSL certificate for these domains:
- `dev.example.com`
- `*.dev.example.com`
- `*.gitlab.dev.example.com`
- `*.gitpod.dev.example.com`
- `*.ws.gitpod.dev.example.com`

You could get a certificate from [Let’s Encrypt](https://letsencrypt.org/) like this:
```shell
$ certbot/certbot certonly \
    --manual \
    --preferred-challenges=dns \
    --email info@example.com \
    --agree-tos \
    -d dev.example.com \
    -d *.dev.example.com \
    -d *.gitlab.dev.example.com \
    -d *.gitpod.dev.example.com \
    -d *.ws.gitpod.dev.example.com
```

The installation script expects the cert files at this positions:
- `gitpod-self-hosted/secrets/https-certificates/fullchain.pem`
- `gitpod-self-hosted/secrets/https-certificates/privkey.pem`


## Installation

The installation script [setup-gitlab-gitpod.sh](setup-gitlab-gitpod.sh) creates 2 k3d clusters: `gitpod` and `gitlab`. It also creates a Docker container with a [nginx](https://www.nginx.com/) reverse proxy that listens on port 443 of the host machine.

Start the installation with
```shell
./setup-gitlab-gitpod.sh dev.example.com 10.0.0.1
```
where `dev.example.com` is your base domain and `10.0.0.1` is your DNS server that resolves the domain. When you omit the DNS server address `8.8.8.8` is used. In this case you domains should be resolved publicly.

When the installation script has been terminated, you could check if everything is up and running by the following commands:
```shell
$ k3d get kubeconfig gitlab --switch
$ kubectl get pods
$ k3d get kubeconfig gitpod --switch
$ kubectl get pods
```
All pods should be `Running` or `Completed`. It takes some time if everything is up and running.

When all pods are running, open https://gitlab.dev.example.com/ and https://gitpod.dev.example.com/workspaces in your browser (replace your base domain).



## Some Notes


### helm error with latest helm version

With the newest helm version the Gitpod helm charts throw an error like this:
> Error: template: gitpod-selfhosted/charts/gitpod/charts/minio/templates/deployment.yaml:192:20: executing "gitpod-selfhosted/charts/gitpod/charts/minio/templates/deployment.yaml" at <(not .Values.gcsgateway.enabled) (not .Values.azuregateway.enabled) (not .Values.s3gateway.enabled) (not .Values.b2gateway.enabled)>: can't give argument to non-function not .Values.gcsgateway.enabled

[gitpod-self-hosted/minio-deployment.patch](gitpod-self-hosted/minio-deployment.patch) is a patch that removes the affected parts since we do not need them for our deployment.


### Gitpod network policies

We remove the network policies of Gitpod since them prevent us from reaching GitLab inside a workspace container. The root cause needs to be further investigated. For now, removing the network policies helps.


### Shared mounts

When a Gitpod workspace starts, the content will be cloned from the repository. For this, we mount the host folder `/tmp/workspaces` into the Gitpod cluster. Feel free to change the path according your needs in the installation script.

To allow Gitpod to mount `/sys/fs/cgroup` the installation script runs the following in the master node container:
```shell
$ mount --make-shared /sys/fs/cgroup
```

### containerd.sock in k3s

The `containerd.sock` in k3s is at `/run/k3s/containerd/containerd.sock`. Thus, `ws-maanger-node` needs to be configures to use the correct path. `gitpod.components.wsManagerNode.containerdSocket=/run/k3s/containerd/containerd.sock` is set in helm upgrade call.

# Multus

A very good article on [Multus](https://thamizhelango.medium.com/complete-guide-to-multus-in-kubernetes-enabling-multiple-network-interfaces-for-pods-857b0b74cf37)

# KinD

This lab is run on [KinD](https://kind.sigs.k8s.io/docs/user/quick-start/). Please use the link to make sure you have it installed before begining.

## Install container networking plugins

**Linux**

You will need macvlan plugin, if you do not have it you will have to install it:

```
sudo apt install containernetworking-plugins -y 
cp -R /usr/lib/cni /opt/.
```
**Podman**

Since Podman runs on a virtual machine, you'll have to install the cni plugins on the VM for the containers to work. These steps have not been tested.

```
podman machine ssh
```
OR

Insert image from podman desktop

Determine architecture and set [cni plugin version](https://github.com/containernetworking/plugins/releases) (at time of writing 1.8)
```
export ARCH_CNI=$( [ $(uname -m) = aarch64 ] && echo arm64 || echo amd64)
export CNI_PLUGIN_VERSION=v1.8.0 # Replace with the latest version
```

Download cni plugin:

```
curl -LO "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-linux-${ARCH_CNI}-${CNI_PLUGIN_VERSION}.tgz"
```

Create directory for plugin:

```
sudo mkdir -p /opt/cni/bin
```

Extract and verify:

```
sudo tar -xzf cni-plugins-linux-${ARCH_CNI}-${CNI_PLUGIN_VERSION}.tgz -C /opt/cni/bin
ls /opt/cni/bin
```

## set env variable

```
export KIND_EXPERIMENTAL_PROVIDER=kind
```

If you plan to use podman:

```
export KIND_EXPERIMENTAL_PROVIDER=podman
```

# Kind Cluster with Calico

```
kind create cluster --config kind-mk-config.yaml --name kalico
```

Please note the networking section, these changes exist so Calico can be installed.

```
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
nodes:
- role: control-plane
- role: worker
networking:
  disableDefaultCNI: true #<- Disables default Kindnetd CNI
  podSubnet: 10.24.0.0/16
```

## View Cluster

```
kubectl get nodes
NAME                   STATUS     ROLES           AGE     VERSION
kalico-control-plane   NotReady   control-plane   6m50s   v1.32.2
kalico-worker          NotReady   <none>          6m40s   v1.32.2
```

## Install Calico

By default, *kind* comes with it's own cni called *kindnetd*. This has been disabled in *kind-mk-config.yaml* and Calico will be installed.


[KIND](https://www.tigera.io/project-calico/)

```
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.2/manifests/tigera-operator.yaml
```

You'll need to run this as we've set a custom cidr block:

```
kubectl apply -f calico-custom-resource.yaml
```

Verify Installation

```
watch kubectl get pods -l k8s-app=calico-node -A
```

## Install Multus

[Multus](https://github.com/k8snetworkplumbingwg/multus-cni) CNI enables attaching multiple network interfaces to pods in Kubernetes.

```
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
```
## Create new networks


You can use `podman` or `docker` to run the below commands based on your container runtime. You are creating this network to attach the new pod interface to this network. This is a real world example of having a BNK internal interface on the same L2 adjacent network as the worker nodes. In the network attachment definition file you will use an IP address in this network.

```
podman ps
```

Make note of the worker node name

```
podman network create -d macvlan ext-net --subnet 10.23.0.0/16
podman network connect ext-net kalico-worker
```

Take note of the [network plugin](https://github.com/containernetworking/plugins) driver used above, `-d macvlan`. Macvlan allows us to assign a unique MAC address to the new interface created by Multus in the Pod. This will also be referenced in the Network Attachment Definition file below.

```
podman exec -it kalico-worker ip a flush eth1
```

This step is not needed, only for bnk deployments outside ocp

```
kubectl annotate --overwrite node kalico-worker 'k8s.ovn.org/node-primary-ifaddr={"ipv4":"10.23.10.10"}'
```

## Network Attachment Definition

Multus uses a network attacment definition file (net-attach-def) to attach additional network interfaces to a Pod. By default, Kubernetes CNI will attach a single
interface, eth0, to a Pod.

Network attachment definition file:

```
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ext-net
spec:
  config: '{
    "cniVersion": "0.3.1",
    "type": "macvlan",    			#<- Driver used
    "master": "eth1",
    "mode": "bridge",
    "ipam": {
      "type": "host-local",			#<- See below for IPAM types
      "subnet": "10.23.0.0/16",		#<- Same network as attached to worker node
      "rangeStart": "10.23.0.100",	#<- net1 interface on Pod will be within the range
      "rangeStop": "10.23.240",
      "routes": [
        { "dst": "0.0.0.0/0"}
        ],
      "gateway": "10.23.0.1"}
    }'
```

NetworkAttachmentDefinition (NAD)

**Definition**: A Kubernetes Custom Resource Definition (CRD) object used to define the specifications for an additional network interface.  

**Functionality**: Each NAD specifies which CNI plugin to use for creating the interface, along with configuration details like the type of network (e.g., SR-IOV, MacVLAN) and the desired IPAM method.  

How it's used: To attach a new interface to a pod, you create a NAD and then annotate the pod to reference that NAD. 

IPAM types

- DHCP: An external DHCP server provides an IP address to the new interface. A DHCP IPAM CNI daemon may be needed to manage the lease.
  
- Static: The interface is assigned a specific, static IP address as part of the NetworkAttachmentDefinition.
  
- Whereabouts: A cluster-wide IPAM plugin that assigns IP addresses from a local pool of addresses. It's a good option for environments that need IP management without an external DHCP server.
   
- Host-local: An IPAM plugin that assigns addresses from a range defined on the local host. When defining a NetworkAttachmentDefinition for use with Multus, the host-local IPAM type specifies that IP address allocation for the secondary network interface will be managed locally on each individual host.


Deploy net-attch-def:

```
kubectl apply -f net-attach-def.yaml
```

# Install Pod

Deploy pod to validate new interface, notice the annotation in the example below:

```
apiVersion: v1
kind: Pod
metadata:
  name: samplepod
  annotations:
    k8s.v1.cni.cncf.io/networks: ext-net #<- annotation is used to denote net-attach-def file
spec:
  containers:
  - name: samplepod
    command: ["/bin/ash", "-c", "trap : TERM INT; sleep infinity & wait"]
    image: alpine
```
Deploy

```
kubectl apply -f samplepod.yaml
```

View details of the *describe* output for samplepod:

```
kubectl descripbe po samplepod
```

```
Name:             samplepod
Namespace:        default
Priority:         0
Service Account:  default
Node:             kalico-worker/10.23.0.1
Start Time:       Thu, 23 Oct 2025 17:09:13 -0700
Labels:           <none>
Annotations:      cni.projectcalico.org/containerID: 18464e9613e89b1a3f6f7ed81df0f7e40bae48451a8857fdde4eef5015948776
                  cni.projectcalico.org/podIP: 10.24.164.132/32
                  cni.projectcalico.org/podIPs: 10.24.164.132/32
                  k8s.v1.cni.cncf.io/network-status:
                    [{
                        "name": "k8s-pod-network",
                        "ips": [
                            "10.24.164.132"
                        ],
                        "default": true,
                        "dns": {}
                    },{
                        "name": "default/ext-net",
                        "interface": "net1",
                        "ips": [
                            "10.23.0.101"
                        ],
                        "mac": "06:d3:55:b9:0f:9c",
                        "dns": {},
                        "gateway": [
                            "\u003cnil\u003e"
                        ]
                    }]
                  k8s.v1.cni.cncf.io/networks: ext-net
Status:           Running
IP:               10.24.164.132
```

From the events you can see *multus* install the the interfaces:
```
Events:
  Type    Reason          Age                From               Message
  ----    ------          ----               ----               -------
  Normal  Scheduled       15h                default-scheduler  Successfully assigned default/samplepod to kalico-worker
  Normal  AddedInterface  15h                multus             Add eth0 [10.24.164.130/32] from k8s-pod-network
  Normal  AddedInterface  15h                multus             Add net1 [10.23.0.100/16] from default/ext-net
  Normal  Pulling         15h                kubelet            Pulling image "alpine"
  Normal  Pulled          15h                kubelet            Successfully pulled image "alpine" in 2.895s (2.895s including waiting). Image size: 3813273 bytes.
```

# Clean up Tasks

## Delete Cluster

```
kind delete cluster --name kalico
```
Or use `cleanup.sh` script

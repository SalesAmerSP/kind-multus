## Install container networking plugins

You will need macvlan plugin, if you do not have it you will have to install it:

```
sudo apt install containernetworking-plugins -y 
cp -R /usr/lib/cni /opt/.
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
  disableDefaultCNI: true
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



```
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
```
## Create new networks


You can use `podman` or `docker` to run the below commands based on your container runtime.

```
podman ps
```

Make note of the worker node name

```
podman network create -d macvlan ext-net --subnet 10.23.0.0/16
podman network connect ext-net kalico-worker
```
```
podman exec -it kalico-worker ip a flush eth1
```

```
kubectl annotate --overwrite node kalico-worker 'k8s.ovn.org/node-primary-ifaddr={"ipv4":"10.23.10.10"}'
```

## Attach

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
		"type": "macvlan",
		"master": "eth1",
		"mode": "bridge",
		"ipam": {}
		}'
```

NetworkAttachmentDefinition (NAD)

Definition: A Kubernetes Custom Resource Definition (CRD) object used to define the specifications for an additional network interface.  

Functionality: Each NAD specifies which CNI plugin to use for creating the interface, along with configuration details like the type of network (e.g., SR-IOV, MacVLAN) and the desired IPAM method.  

How it's used: To attach a new interface to a pod, you create a NAD and then annotate the pod to reference that NAD.  
IPAM types

- DHCP: An external DHCP server provides an IP address to the new interface. A DHCP IPAM CNI daemon may be needed to manage the lease.
-  
- Static: The interface is assigned a specific, static IP address as part of the NetworkAttachmentDefinition.
-  
- Whereabouts: A cluster-wide IPAM plugin that assigns IP addresses from a local pool of addresses. It's a good option for environments that need IP management without an external DHCP server.
   
- Host-local: An IPAM plugin that assigns addresses from a range defined on the local host. When defining a NetworkAttachmentDefinition for use with Multus, the host-local IPAM type specifies that IP address allocation for the secondary network interface will be managed locally on each individual host.


Deploy net-attch-def:

```
kubectl apply -f net-attach-def.yaml
```

Deploy pod to validate new interface:

```
kubectl apply -f samplepod.yaml
```

```
apiVersion: v1
kind: Pod
metadata:
  name: samplepod
  annotations:
    k8s.v1.cni.cncf.io/networks: ext-net
spec:
  containers:
  - name: samplepod
    command: ["/bin/ash", "-c", "trap : TERM INT; sleep infinity & wait"]
    image: alpine
```

## Install Container

```
kubectl run nginx-single-nic --image=nginx:latest
```

Check pod ip addrress

delete pod 

```
kubectl delete po nginx-sincle-nic
```

# Clean up Tasks

## Delete Cluster

```
kind delete cluster kalico
```
Or use `cleanup.sh` script

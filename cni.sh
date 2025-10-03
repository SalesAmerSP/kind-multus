kind create cluster --config kind-mk-config.yaml --name kalico
sleep 3
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.2/manifests/tigera-operator.yaml
sleep 10
kubectl apply -f calico-custom-resource.yaml
sleep 10

max=10
for ((i=0;i< max; i++));
do
  kready=$(kubectl get nodes | grep -w Ready | wc -l)
  if [[ $kready -ne 2 ]]; then
    echo "${kready} node(s) Ready"
    sleep 5
  fi
done 
dnet=$(docker network ls | grep ext-net)
if [[ !$dnet ]]; then
  echo "ext-net does not exist, creating now.."
  docker network create -d macvlan ext-net --subnet 10.23.0.0/16
  sleep 3
  docker network connect ext-net kalico-worker
  sleep 3
else
   docker network connect ext-net kalico-worker
fi

#docker exec -it kalico-worker ip a flush eth1
#sleep 2
echo "Apply Multus.."
#kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml
sleep 3
kubectl apply -f net-attach-def.yaml
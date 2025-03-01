#!/usr/bin/env bash
set -eo pipefail
unset CDPATH

for i in "$@"
do
case $i in
    -n=*|--namespace=*)
    NAMESPACE="${i#*=}"
    ;;
    --add-hosts)
    ADD_HOSTS="YES"
    ;;
    *)
            # unknown option
    ;;
esac
done

if [ -z "$NAMESPACE" ]
then
	NAMESPACE="kube-public"
fi

registry_host="trow.$NAMESPACE"
registry_port="31000"
registry_host_port="${registry_host}:${registry_port}"
add_host_ip=""

function get_ip_from_k8s {

  add_host_ip=""
  local schedulable_nodes=""
  schedulable_nodes="$(kubectl get nodes -o template \
    --template='{{range.items}}{{if not .spec.unschedulable}}{{range.status.addresses}}{{if eq .type "ExternalIP"}}{{.address}} {{end}}{{end}}{{end}}{{end}}')" 

  for n in $schedulable_nodes 
  do
    add_host_ip=$n
    break
  done

  if [[ -z "$add_host_ip" ]]; then
    echo
    echo 'No external IP listed in "kubectl get nodes -o wide"'
    echo "Trying minikube"

    set +e
    add_host_ip=$(minikube ip 2>/dev/null)
    set -e
    if [[ -z "$add_host_ip" ]]; then
      echo "Not minikube."
      echo "Trying internal IP which may work for local clusters e.g. microk8s"

      schedulable_nodes="$(kubectl get nodes -o template \
        --template='{{range.items}}{{if not .spec.unschedulable}}{{range.status.addresses}}{{if eq .type "InternalIP"}}{{.address}} {{end}}{{end}}{{end}}{{end}}')" 

      for n in $schedulable_nodes 
      do
        add_host_ip=$n
        break
      done

      if [[ -z "$add_host_ip" ]]; then
        echo "Assuming running on localhost. This might work if 
running Docker for Mac..."
        add_host_ip="127.0.0.1"
      fi
    fi
  fi
}

function add_to_etc_hosts { 
  echo
  echo "Exposing registry via /etc/hosts"

  # sed would be a better choice than ed, but it wants to create a temp file :(
  # redirectred stderr here, as ed likes to write to it even in success case

  if [[ -n "$add_host_ip" ]]; then
    echo "This requires sudo privileges"
    printf "g/%s/d\nw\n" "$add_host_name" \
      | sudo ed /etc/hosts 2> /dev/null

    echo "$add_host_ip $add_host_name # added for trow registry" \
      | sudo tee -a /etc/hosts
  else
    echo
    echo "Failed to find external address for cluster" >&2
    exit 2
  fi
  echo 
  echo "Successfully configured localhost"
  return 0
}
########
# MAIN #
########

#Copy cert to host

echo "Copying cert into Docker"
echo "This requires sudo privileges"
sudo mkdir -p "/etc/docker/certs.d/$registry_host_port/"

on_mac=false
if [[ "$(uname -s)" = "Darwin" ]]; then
  on_mac=true
fi

cert_file=$(mktemp /tmp/cert.XXXXXX)
kubectl -n $NAMESPACE get secret root-secret -o jsonpath="{.data.ca\.crt}" | base64 --decode \
    | tee -a $cert_file

if "$on_mac"; then
  echo "Assuming running Docker for Mac - adding certificate to Docker keychain"
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$cert_file"
  echo 
  echo "Certificate added"
  echo "Restart Docker for Mac for this to take effect."
else #On linux
  sudo cp "$cert_file" "/etc/docker/certs.d/$registry_host_port/ca.crt"
  echo "Successfully copied cert"
fi

if [[ "$ADD_HOSTS" = "YES" ]]; then
  echo "Adding entry to /etc/hosts for trow.$NAMESPACE" 
  get_ip_from_k8s
  add_host_name="trow.$NAMESPACE"
  add_to_etc_hosts
fi

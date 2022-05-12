#!/bin/bash
#
#  Work In Progress - File not currently used!!
#  Looking to remove the Post-Install scripting out of the react app, and to just call a bash file
#  This way, the UI and the github actions can call a common script for all the cluster post-install configuration
#

# Fail if any command fails
set -e


agw=""
vnet_opt=""
ingress=""
apisecurity=""
monitor=""
enableMonitorIngress="false"
ingressEveryNode=""
dnsZoneId=""
denydefaultNetworkPolicy=""
certEmail=""

while getopts "p:g:n:r:" opt; do
  case ${opt} in
    p )
        IFS=',' read -ra params <<< "$OPTARG"
        for i in "${params[@]}"; do
            if [[ $i =~ (agw|vnet_opt|ingress|apisecurity|monitor|enableMonitorIngress|ingressEveryNode|dnsZoneId|denydefaultNetworkPolicy|certEmail)=([^ ]*) ]]; then
                echo "set ${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
                declare ${BASH_REMATCH[1]}=${BASH_REMATCH[2]}
            else
                echo "Unknown paramter $i"
                show_usage=true
                break
            fi
        done
      ;;

    g )
     rg=$OPTARG
     ;;

    n )
     aks=$OPTARG
     ;;
    r )
     release_url=$OPTARG
     ;;
    \? )
      echo "Unknown arg"
      show_usage=true

      ;;
  esac
done

dnsZoneId_domain=""
if [ "$dnsZoneId" ]; then
    if [[ $dnsZoneId =~ ^/subscriptions/([^/ ]+)/resourceGroups/([^/ ]+)/providers/Microsoft.Network/(dnszones|privateDnsZones)/([^/ ]+)$ ]]; then
        dnsZoneId_sub=${BASH_REMATCH[1]}
        dnsZoneId_rg=${BASH_REMATCH[2]}
        dnsZoneId_type=${BASH_REMATCH[3]}
        dnsZoneId_domain=${BASH_REMATCH[4]}
    else
        echo "dnsZoneId paramter needs to be a resourceId format for Azure DNS Zone"
        show_usage=true
    fi

fi

if [ "$ingressEveryNode" ] && [[ ! $ingressEveryNode = "true" ]]; then
 echo "supported ingressEveryNode paramter values (true)"
 show_usage=true
fi

if [ "$denydefaultNetworkPolicy" ] && [[ ! $denydefaultNetworkPolicy = "true" ]]; then
 echo "supported denydefaultNetworkPolicy paramter values (true)"
 show_usage=true
fi

if [ "$ingress" ] && [[ ! $ingress =~ (appgw|contour|nginx) ]]; then
 echo "supported ingress paramter values (appgw|contour|nginx)"
 show_usage=true
fi

if [ "$ingressEveryNode" ] && [[ $ingress = "appgw" ]]; then
 echo "ingressEveryNode only supported if ingress paramter is (nginx|contour)"
 show_usage=true
fi


if [ -z "$agw" ] && [ "$ingress" = "appgw" ]; then
 echo "If ingress=appgw, please provide a 'agw' parameter"
 show_usage=true
fi

if [  "$monitor" ] && [[ ! "$monitor" = "oss" ]]; then
 echo "supported monitor parameter values are (oss)"
 show_usage=true
fi

if [ -z "$rg" ] || [ -z "$aks" ] || [ "$show_usage" ]; then
    echo "Usage: $0"
    echo "args:"
    echo " < -g resource-group> (required)"
    echo " < -n aks-name> (required)"
    echo " [ -p: parameters] : Can provide one or multiple features:"
    echo "     agw=<name> - Name of Application Gateway"
    echo "     vnet_opt=byo - Deployed AKS into BYO Vnet"
    echo "     ingress=<appgw|contour|nginx> - Enable cluster AutoScaler with max nodes"
    echo "     apisecurity=<max> - Enable cluster AutoScaler with max nodes"
    echo "     monitor=<oss> - Enable cluster AutoScaler with max nodes"
    echo "     enableMonitorIngress=<true> - Enable Ingress for Promethous"
    echo "     ingressEveryNode=<true> - Enable cluster AutoScaler with max nodes"
    echo "     denydefaultNetworkPolicy=<true> - Deploy deny all network police"
    echo "     dnsZoneId=<Azure DNS Zone resourceId> - Enable cluster AutoScaler with max nodes"
    echo "     certEmail=<email for certman certificates> - Enables cert-manager"
    exit 1
fi


EXTERNAL_DNS_REGISTRY="k8s.gcr.io"
EXTERNAL_DNS_REPO="external-dns/external-dns"
# appVersion :: https://raw.githubusercontent.com/kubernetes-sigs/external-dns/master/charts/external-dns/Chart.yaml
EXTERNAL_DNS_TAG="v0.10.2"


if [ "$vnet_opt" = "byo" ] && [ "$ingress" = "appgw" ]; then
    echo "# ------------------------------------------------"
    echo "#          Workaround to enable AGIC with BYO VNET"
    APPGW_RG_ID="$(az group show -n ${rg} --query id -o tsv)"
    APPGW_ID="$(az network application-gateway show -g ${rg} -n ${agw} --query id -o tsv)"
    az aks enable-addons -n ${aks} -g ${rg} -a ingress-appgw --appgw-id $APPGW_ID

    AKS_AGIC_IDENTITY_ID="$(az aks show -g ${rg} -n ${aks} --query addonProfiles.ingressApplicationGateway.identity.objectId -o tsv)"
    az role assignment create --role "Contributor" --assignee-principal-type ServicePrincipal --assignee-object-id $AKS_AGIC_IDENTITY_ID --scope $APPGW_ID
    az role assignment create --role "Reader" --assignee-principal-type ServicePrincipal --assignee-object-id $AKS_AGIC_IDENTITY_ID --scope $APPGW_RG_ID

    #  additionally required if appgwKVIntegration (app gateway has assigned identity)
    if true; then

        APPGW_IDENTITY="$(az network application-gateway show -g ${rg} -n ${agw} --query 'keys(identity.userAssignedIdentities)[0]' -o tsv)"
        az role assignment create --role "Managed Identity Operator" --assignee-principal-type ServicePrincipal --assignee-object-id $AKS_AGIC_IDENTITY_ID --scope $APPGW_IDENTITY
    fi
fi

if [ "$dnsZoneId"  ] && [ "$ingress" ]; then

    KubeletId=$(az aks show -g ${rg} -n ${aks} --query identityProfile.kubeletidentity.clientId -o tsv)
    TenantId=$(az account show --query tenantId -o tsv)

        if [ "$apisecurity" = "private" ]; then
            # Import external-dns Image to ACR
            export ACRNAME=$(az acr list -g ${rg} --query [0].name -o tsv)
            az acr import -n $ACRNAME --source ${EXTERNAL_DNS_REGISTRY}/${EXTERNAL_DNS_REPO}:${EXTERNAL_DNS_TAG} --image ${EXTERNAL_DNS_REPO}:${EXTERNAL_DNS_TAG}
        fi
fi

ingress_controller_kind="deployment"
ingress_externalTrafficPolicy="cluster"
if [ "$ingressEveryNode" ]; then
    ingress_controller_kind="daemonset"
    ingress_externalTrafficPolicy="local"
fi
ingress_metrics_enabled=false
if [ "$monitor" = "oss" ]; then
    ingress_metrics_enabled=true
fi

if [ "$ingress" = "nginx" ]; then

    nginx_namespace="ingress-basic"
    nginx_helm_release_name="nginx-ingress"

    echo "# ------------------------------------------------"
    echo "#                 Install Nginx Ingress Controller"
    kubectl create namespace ${nginx_namespace} --dry-run=client -o yaml | kubectl apply -f -
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm upgrade --install ${nginx_helm_release_name} ingress-nginx/ingress-nginx \
        --set controller.publishService.enabled=true \
        --set controller.kind=${ingress_controller_kind} \
        --set controller.service.externalTrafficPolicy=${ingress_externalTrafficPolicy} \
        --set controller.metrics.enabled=${ingress_metrics_enabled} \
        --set controller.metrics.serviceMonitor.enabled=${ingress_metrics_enabled} \
        --set controller.metrics.serviceMonitor.namespace=${prometheus_namespace} \
        --set controller.metrics.serviceMonitor.additionalLabels.release=${prometheus_helm_release_name} \
        --namespace ${nginx_namespace}
fi

if [ "$ingress" = "contour" ]; then

    contour_namespace="ingress-basic"
    contour_helm_release_name="contour-ingress"
    # https://artifacthub.io/packages/helm/bitnami/contour
    echo "# ------------------------------------------------"
    echo "#               Install Contour Ingress Controller"
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm upgrade --install ${contour_helm_release_name} bitnami/contour --namespace ${contour_namespace} --create-namespace \
        --set envoy.kind=${ingress_controller_kind} \
        --set contour.service.externalTrafficPolicy=${ingress_externalTrafficPolicy} \
        --set metrics.serviceMonitor.enabled=${ingress_metrics_enabled} \
        --set commonLabels."release"=${prometheus_helm_release_name} \
        --set metrics.serviceMonitor.namespace=${prometheus_namespace}
fi


# External DNS
# external-dns needs permissions to make changes in the Azure DNS server.
# https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/azure.md#azure-managed-service-identity-msi
if [ "$dnsZoneId" ]; then

    echo "# ------------------------------------------------"
    echo "#                             Install external-dns"
    kubectl create secret generic aks-kube-msi --from-literal=azure.json="{
        userAssignedIdentityID: $KubeletId,
        tenantId: $TenantId,
        useManagedIdentityExtension: true,
        subscriptionId: ${dnsZoneId_sub},
        resourceGroup: ${dnsZoneId_rg}
    }" --dry-run=client -o yaml | kubectl apply -f -

    provider="azure"
    if [ "$dnsZoneId_type" = "privateDnsZones" ]; then
        provider="azure-private-dns"
    fi

    dnsImageRepo="${EXTERNAL_DNS_REGISTRY}/${EXTERNAL_DNS_REPO}:${EXTERNAL_DNS_TAG}"
    if [ "$apisecurity" = "private" ]; then
        dnsImageRepo="${ACRNAME}.azurecr.io/${EXTERNAL_DNS_REPO}"
    fi

    helm upgrade --install externaldns https://github.com/kubernetes-sigs/external-dns/releases/download/external-dns-helm-chart-1.7.1/external-dns-1.7.1.tgz \
    --set domainFilters={"${dnsZoneId_domain}"} \
    --set provider="${provider}" \
    --set extraVolumeMounts[0].name=aks-kube-msi,extraVolumeMounts[0].mountPath=/etc/kubernetes,extraVolumeMounts[0].readOnly=true \
    --set extraVolumes[0].name=aks-kube-msi,extraVolumes[0].secret.secretName=aks-kube-msi \
    --set image.repository=${dnsImageRepo} \
    --set image.tag=${EXTERNAL_DNS_TAG}
fi

ingressClass=$ingress
if [ "$ingress" = "appgw" ]; then
    ingressClass="azure/application-gateway"
fi

if [ "$certEmail" ]; then

    echo "# ------------------------------------------------"
    echo "#                             Install cert-manager"

    certMan_Version="v1.6.0"
    if [ "$ingress" = "appgw" ]; then
        echo "Downgrading cert-manager for AppGateway IC"
        certMan_Version="v1.5.3"
    fi

    certIssuerPath=""
    if [ "$apisecurity" = "private" ]; then
        certIssuerPath="/postdeploy/helm"
    fi

    kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/${certMan_Version}/cert-manager.yaml
    sleep 30s # wait for cert-manager webhook to install
    helm upgrade --install letsencrypt-issuer ${release_url:-.}${certIssuerPath}/Az-CertManagerIssuer-0.3.0.tgz \
        --set email=${certEmail}  \
        --set ingressClass=${ingressClass}
fi

prometheus_namespace="monitoring"
prometheus_helm_release_name="monitoring"

if [ "$monitor" = "oss" ]; then
    echo "# ------------------------------------------------"
    echo "#              Install kube-prometheus-stack chart"
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    kubectl create namespace ${prometheus_namespace} --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install ${prometheus_helm_release_name} prometheus-community/kube-prometheus-stack --namespace ${prometheus_namespace} \
        --set grafana.ingress.enabled=${enableMonitorIngress} \
        --set grafana.ingress.annotations."cert-manager\.io/cluster-issuer"=letsencrypt-prod \
        --set grafana.ingress.annotations."ingress\.kubernetes\.io/force-ssl-redirect"=\"true\" \
        --set grafana.ingress.ingressClassName=${ingressClass} \
        --set grafana.ingress.hosts[0]=grafana.${dnsZoneId_domain} \
        --set grafana.ingress.tls[0].hosts[0]=grafana.${dnsZoneId_domain},grafana.ingress.tls[0].secretName=aks-grafana
fi


if [ "$denydefaultNetworkPolicy" ]; then
    echo "# ----------- Default Deny All Network Policy, east-west traffic in cluster"
    kubectl apply -f ${release_url:-.}/postdeploy/k8smanifests/networkpolicy-deny-all.yml
fi

#!/bin/sh

# This bash/azure cli script will create a resource group, aks cluster, akv, and connect aks/akv using a managed identiy.
# 
# It generally follows the steps in https://learn.microsoft.com/en-us/azure/aks/csi-secrets-store-identity-access#access-with-an-azure-ad-workload-identity
# but includes additional steps to create resources and configure for deployment to Azure Government

export SUBSCRIPTION_ID="<SUBSCRIPTION_id>"
export RESOURCE_GROUP=tm5-aks-rg
export UAMI=tm5-aks-uami
export KEYVAULT_NAME=tm5-aks-akv
export CLUSTER_NAME=tm5-aks
export CLOUD_NAME=AzureUSGovernment # use "AzurePublic" for public clouds
export LOCATION=usgovvirginia

# 1 set subscription
az cloud set --name $CLOUD_NAME
az account set --subscription $SUBSCRIPTION_ID

# 1.1 TMM: Create RG
az group create --name ${RESOURCE_GROUP} --location ${LOCATION}

# 1.2 TMM: Create AKS
az aks create -g ${RESOURCE_GROUP}  --name ${CLUSTER_NAME} --node-count 1 \
  --enable-addons azure-keyvault-secrets-provider \
  --enable-managed-identity \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --generate-ssh-keys
az aks get-credentials -g ${RESOURCE_GROUP}  --name ${CLUSTER_NAME}


# 1.3 TMM: Create AKV & Secret
az keyvault create --name $KEYVAULT_NAME -g $RESOURCE_GROUP  --location $LOCATION
az keyvault secret set --vault-name $KEYVAULT_NAME --name "demosecret" --value "ThisIsMyDemoSecret!"


# 2 create managed id
az identity create --name $UAMI --resource-group $RESOURCE_GROUP
export USER_ASSIGNED_CLIENT_ID="$(az identity show -g $RESOURCE_GROUP --name $UAMI --query 'clientId' -o tsv)"
export IDENTITY_TENANT=$(az aks show --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP --query identity.tenantId -o tsv)


# 3 grant AKV access to UMAI
az keyvault set-policy -n $KEYVAULT_NAME --key-permissions get --spn $USER_ASSIGNED_CLIENT_ID
az keyvault set-policy -n $KEYVAULT_NAME --secret-permissions get --spn $USER_ASSIGNED_CLIENT_ID
az keyvault set-policy -n $KEYVAULT_NAME --certificate-permissions get --spn $USER_ASSIGNED_CLIENT_ID


# 4 Get OIDC Issuer URL
export AKS_OIDC_ISSUER="$(az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --query "oidcIssuerProfile.issuerUrl" -o tsv)"
echo $AKS_OIDC_ISSUER


# 5 Create the Service Account

export SERVICE_ACCOUNT_NAME="workload-identity-sa"  # sample name; can be changed
export SERVICE_ACCOUNT_NAMESPACE="default" # can be changed to namespace of your workload

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: ${USER_ASSIGNED_CLIENT_ID}
  labels:
    azure.workload.identity/use: "true"
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
EOF

# 6 Create Federated ID
export FEDERATED_IDENTITY_NAME="aksfederatedidentity" # can be changed as needed
az identity federated-credential create --name $FEDERATED_IDENTITY_NAME --identity-name $UAMI --resource-group $RESOURCE_GROUP \
  --issuer ${AKS_OIDC_ISSUER} \
  --subject system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}

# 7. Deploy SecretProvider Class
cat <<EOF | kubectl apply -f -
# This is a SecretProviderClass example using workload identity to access your key vault
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: azure-kvname-workload-identity # needs to be unique per namespace
spec:
  provider: azure
  secretObjects:
  - secretName: aks-secret # name given to our kubernetes secret
    type: Opaque
    data:
    - objectName: demosecret # must match objectName below
      key: demosecret # this can be called what you want, this is to reference this object.  
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "false"          
    clientID: "${USER_ASSIGNED_CLIENT_ID}" # Setting this to use workload identity
    keyvaultName: ${KEYVAULT_NAME}       # Set to the name of your key vault
    cloudName: "$CLOUD_NAME"       # [OPTIONAL for Azure] if not provided, the Azure environment defaults to AzurePublicCloud
    objects:  |
      array:
        - |
          objectName: demosecret
          objectType: secret              # object types: secret, key, or cert
          objectVersion: ""               # [OPTIONAL] object versions, default to latest if empty
    tenantId: "${IDENTITY_TENANT}"        # The tenant ID of the key vault
EOF


# 8. Deploy example pod

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: docker-getting-started
spec:
  serviceAccountName: ${SERVICE_ACCOUNT_NAME}
  containers:
    - name: docker-getting-started
      image: docker/getting-started
      env:
      - name: MY_KV_SECRET # environment variable to set inside container
        valueFrom:
          secretKeyRef:
            name: aks-secret # name of our kubernetes secret
            key: demosecret # key specified in kubernetes secret 
      volumeMounts:
        - name: secret-volume # same name as volume below
          mountPath: "/mnt/secrets"
          readOnly: true
  volumes:
    - name: secret-volume # given name to volume
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: azure-kvname-workload-identity # name of secret provider class created in previous step
EOF

sleep 10

# Prints env, look for MY_KV_SECRET variable
kubectl exec -it docker-getting-started -- printenv

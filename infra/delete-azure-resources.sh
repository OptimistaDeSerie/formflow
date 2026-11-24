#!/usr/bin/env bash
# Deletes the whole resource group, which removes the VM, its disk, its public IP and its network.
# Run it when you have finished your screenshots and demo, so Azure stops charging you.
set -euo pipefail

RG="${RG:-formflow-rg}"

command -v az >/dev/null 2>&1 || { echo "The Azure CLI (az) was not found."; exit 1; }

if [ "$(az group exists --name "$RG")" != "true" ]; then
  echo "The resource group $RG does not exist. Nothing to delete."
  exit 0
fi

echo "This will permanently delete everything inside $RG:"
az resource list --resource-group "$RG" --query "[].{name:name, type:type}" --output table
echo
read -r -p "Type the group name ($RG) to confirm: " ANSWER
if [ "$ANSWER" != "$RG" ]; then
  echo "Names did not match. Nothing was deleted."
  exit 1
fi

az group delete --name "$RG" --yes --no-wait
echo "Deletion started. It takes a few minutes. Check with:"
echo "  az group exists --name $RG      (prints false when it is gone)"

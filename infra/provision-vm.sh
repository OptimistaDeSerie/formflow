#!/usr/bin/env bash
# Creates the Azure resources for FormFlow: one resource group, one Linux VM, port 80 open.
# Requires bash and the Azure CLI, already logged in (az login).
#
# How it stays safe:
#   - Before creating anything it asks Azure itself ("az vm create --validate") whether the
#     subscription may create each region and size in the list. That check includes the VM core
#     quota, and it creates nothing and costs nothing.
#   - It waits for a typed "yes" before the first resource that costs money is created.
#
# Optional overrides (all four have safe defaults). REGION and SIZE accept one name or several
# names separated by spaces, which are tried in order:
#   RG=formflow-rg   VM=formflow-vm   REGION="westus3 swedencentral"   SIZE=Standard_B2ats_v2
set -euo pipefail

# Suppress harmless Python warnings printed by the Azure CLI, so the output stays readable.
export PYTHONWARNINGS=ignore
export AZURE_CORE_ONLY_SHOW_ERRORS=true

RG="${RG:-formflow-rg}"
VM="${VM:-formflow-vm}"
ADMIN_USER="azureuser"
IMAGE="Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest"   # Ubuntu 22.04 LTS

# Cheapest first. New subscriptions often have blocked sizes or zero quota, so there are many fallbacks.
DEFAULT_SIZES=(Standard_B1s Standard_B2ats_v2 Standard_B2ts_v2 Standard_B1ms Standard_B2s \
  Standard_B2als_v2 Standard_B2ls_v2 Standard_A1_v2 Standard_A2_v2 Standard_DS1_v2 \
  Standard_D2as_v5 Standard_D2s_v5 Standard_D2s_v3 \
  Standard_D2ads_v6 Standard_D2as_v6 Standard_D2ds_v6 Standard_D2s_v6)
DEFAULT_REGIONS=(eastus eastus2 westus3 uksouth francecentral northeurope westeurope centralus westus2 \
  swedencentral polandcentral southafricanorth)

if [ -n "${SIZE:-}" ];   then read -r -a SIZES <<< "${SIZE//,/ }";     else SIZES=("${DEFAULT_SIZES[@]}");     fi
if [ -n "${REGION:-}" ]; then read -r -a REGIONS <<< "${REGION//,/ }"; else REGIONS=("${DEFAULT_REGIONS[@]}"); fi

# One definition of the VM settings, used for the free check AND for the real creation,
# so the check tests exactly what will be created.
# Usage: vm_create REGION SIZE [extra az arguments]
vm_create() {
  local loc="$1" size="$2"
  shift 2
  az vm create \
    --resource-group "$RG" \
    --name "$VM" \
    --location "$loc" \
    --image "$IMAGE" \
    --size "$size" \
    --admin-username "$ADMIN_USER" \
    --generate-ssh-keys \
    --public-ip-sku Standard \
    --storage-sku StandardSSD_LRS \
    --tags project=formflow \
    "$@"
}

# Throws away anything typed while the script was busy, so stray Enter presses
# cannot answer the question below by accident.
flush_keyboard() {
  if [ -t 0 ]; then
    while read -r -t 1 -s -n 10000 _junk; do :; done
  fi
  return 0
}

# Reads Azure's error text and sets KIND (and sometimes DETAIL):
#   quota    this VM family has no (or too little) core quota in this region
#   regional the total core quota of this region is used up
#   sku      this size is not allowed for the subscription in this region
#   region   this whole region is closed to the subscription (policy, or not accepting new customers)
#   fatal    login or permission problem, no point trying more
#   other    anything else (DETAIL holds the short reason)
KIND=""; DETAIL=""
classify_error() {
  local e="$1" lim code msg
  KIND="other"; DETAIL=""
  if grep -q -E 'AADSTS|az login' <<< "$e"; then
    KIND="fatal"; DETAIL="your Azure login has expired. Run: az login"
  elif grep -q 'AuthorizationFailed' <<< "$e"; then
    KIND="fatal"; DETAIL="your account is not allowed to create VMs in this subscription"
  elif grep -q 'QuotaExceeded' <<< "$e"; then
    lim="$(sed -n 's/.*Current Limit: \([0-9][0-9]*\).*/\1/p' <<< "$e" | head -1)"
    if grep -q 'Total Regional' <<< "$e"; then
      KIND="regional"; DETAIL="limit ${lim:-0}"
    else
      KIND="quota"; DETAIL="limit ${lim:-0}"
    fi
  elif grep -q -E 'SkuNotAvailable|NotAvailableForSubscription' <<< "$e"; then
    KIND="sku"
  elif grep -q -E 'locationineligible|not accepting new customers' <<< "$e"; then
    KIND="region"; DETAIL="Azure says this region is not accepting new customers"
  elif grep -q -E 'RequestDisallowedByPolicy|LocationNotAvailableForResourceType|RequestDisallowedByAzure' <<< "$e"; then
    KIND="region"
  else
    code="$(grep -E '^[[:space:]]*Code:' <<< "$e" | tail -1 | sed 's/^[[:space:]]*Code:[[:space:]]*//' || true)"
    msg="$(grep -E '^[[:space:]]*Message:' <<< "$e" | tail -1 | sed 's/^[[:space:]]*Message:[[:space:]]*//' | cut -c1-300 || true)"
    if [ -z "$msg" ]; then
      msg="$(grep -v -i -E 'warn|^[[:space:]]*$' <<< "$e" | head -1 | cut -c1-300 || true)"
    fi
    DETAIL="${code:-error}: $msg"
  fi
}

# Has a smaller or equal size of this family (or of this whole region) already failed on quota?
# QUOTA_FAILS holds entries like "eastus|standardBasv2Family|2" separated by spaces.
QUOTA_FAILS=""
quota_known_bad() {
  local r="$1" fam="$2" cpus="$3" e er rest ef ev
  for e in $QUOTA_FAILS; do
    er="${e%%|*}"; rest="${e#*|}"; ef="${rest%%|*}"; ev="${rest#*|}"
    if [ "$er" = "$r" ] && { [ "$ef" = "$fam" ] || [ "$ef" = "ALL" ]; } && [ "$cpus" -ge "$ev" ]; then
      return 0
    fi
  done
  return 1
}

show() { printf '  %-15s %-19s %s\n' "$1" "$2" "$3"; }

echo "== 1. Checking the Azure CLI and your login =="
command -v az >/dev/null 2>&1 || { echo "The Azure CLI (az) was not found. Fix that first."; exit 1; }
if ! az account show >/dev/null 2>&1; then
  echo "You are not logged in. Run: az login   then run this script again."
  exit 1
fi
az account show --query "{subscription:name, state:state}" --output table 2>/dev/null

echo
echo "== 2. Checking that Azure services are switched on for your subscription =="
for ns in Microsoft.Compute Microsoft.Network Microsoft.Storage; do
  state="$(az provider show --namespace "$ns" --query registrationState --output tsv 2>/dev/null)"
  if [ "$state" = "Registered" ]; then
    echo "$ns: Registered"
  else
    echo "$ns: $state. Registering now (free, can take a few minutes)..."
    az provider register --namespace "$ns" --wait
    echo "$ns: Registered"
  fi
done

echo
echo "== 3. Preparing the resource group (an empty folder for the VM's parts, free) =="
RG_NEW="no"
if [ "$(az group exists --name "$RG" 2>/dev/null)" = "true" ]; then
  COUNT="$(az resource list --resource-group "$RG" --query "length(@)" --output tsv 2>/dev/null || echo "?")"
  if [ "$COUNT" = "0" ]; then
    echo "$RG already exists and is empty. Reusing it."
  else
    echo "The resource group $RG already contains $COUNT item(s) (count '?' means Azure could not be asked)."
    echo "Delete it first with: bash infra/delete-azure-resources.sh   or run with RG=another-name. Nothing was created."
    exit 1
  fi
else
  az group create --name "$RG" --location "${REGIONS[0]}" --tags project=formflow --output none
  RG_NEW="yes"
  echo "$RG created in ${REGIONS[0]} (empty, free)."
fi

echo
echo "== 4. Asking Azure which region and size your subscription may really create =="
echo "Each line is a free check. Nothing is created. This can take a few minutes."
LOC=""; VMSIZE=""
for r in "${REGIONS[@]}"; do
  SKUTXT="$(az vm list-skus --location "$r" --resource-type virtualMachines --all \
    --query "[].[name, family, capabilities[?name=='vCPUs'] | [0].value, length(restrictions[?type=='Location'])]" \
    --output tsv 2>/dev/null || true)"
  if [ -z "$SKUTXT" ]; then
    show "$r" "" "could not read the size list for this region, skipping"
    continue
  fi
  shown=0
  for s in "${SIZES[@]}"; do
    row="$(awk -F'\t' -v s="$s" '$1==s {print; exit}' <<< "$SKUTXT")"
    [ -n "$row" ] || continue                       # size does not exist in this region
    IFS=$'\t' read -r _name family vcpus restricted <<< "$row"
    case "$vcpus" in ''|*[!0-9]*) vcpus=1 ;; esac
    case "$restricted" in ''|*[!0-9]*) restricted=0 ;; esac
    if [ "$restricted" != "0" ]; then
      show "$r" "$s" "blocked for your subscription here"; shown=1
      continue
    fi
    if quota_known_bad "$r" "$family" "$vcpus"; then
      continue                                      # same family already failed on quota here
    fi
    printf '  %-15s %-19s ' "$r" "$s"
    shown=1
    if err="$(vm_create "$r" "$s" --validate --output none 2>&1 >/dev/null)"; then
      echo "AVAILABLE (Azure's check passed)"
      LOC="$r"; VMSIZE="$s"
      break 2
    fi
    classify_error "$err"
    case "$KIND" in
      quota)
        echo "no quota for $family here ($DETAIL cores)"
        QUOTA_FAILS="$QUOTA_FAILS $r|$family|$vcpus" ;;
      regional)
        echo "this region's total core quota is full ($DETAIL)"
        QUOTA_FAILS="$QUOTA_FAILS $r|ALL|$vcpus" ;;
      sku)
        echo "not allowed for your subscription here" ;;
      region)
        echo "${DETAIL:-this region is not allowed for your subscription}"
        break ;;
      fatal)
        echo "stopped"
        echo
        echo "Azure says: $DETAIL"
        echo "NOTHING was created and nothing is being charged."
        exit 1 ;;
      *)
        echo "blocked"
        printf 'Azure says: %s\n' "$DETAIL" | fold -s -w 88 | sed 's/^/    /' ;;
    esac
  done
  if [ "$shown" -eq 0 ]; then
    show "$r" "" "none of the listed sizes is offered here"
  fi
done

if [ -z "$LOC" ]; then
  if [ "$RG_NEW" = "yes" ]; then
    az group delete --name "$RG" --yes --no-wait --output none 2>/dev/null || true
  fi
  echo
  echo "Azure's check refused every region and size in the list. NOTHING was created and nothing is being charged."
  echo "The usual cause on a new subscription is VM core quota: Azure gives some accounts a limit of 0 cores"
  echo "for some VM types in some regions. You can ask Azure to raise it in the portal under"
  echo "Quotas > Compute, or open a free support request there. To test other regions only, for example:"
  echo "  REGION=\"westus3 swedencentral\" bash infra/provision-vm.sh"
  echo "Share this whole output when asking for help."
  exit 1
fi

echo
echo "== 5. Price estimate (Azure public price list, Linux, pay-as-you-go) =="
PRICE="$(curl -fsS -m 15 -G "https://prices.azure.com/api/retail/prices" \
  --data-urlencode "\$filter=serviceName eq 'Virtual Machines' and armRegionName eq '$LOC' and armSkuName eq '$VMSIZE' and priceType eq 'Consumption'" 2>/dev/null \
  | python3 -c '
import json, sys
try:
    items = json.load(sys.stdin).get("Items", [])
    ok = [i["retailPrice"] for i in items
          if i.get("unitOfMeasure") == "1 Hour"
          and "Windows" not in i.get("productName", "")
          and "Spot" not in i.get("skuName", "")
          and "Low Priority" not in i.get("skuName", "")]
    print("%.4f" % min(ok) if ok else "")
except Exception:
    print("")
' 2>/dev/null || true)"
if [ -n "$PRICE" ]; then
  echo "About \$$PRICE per hour for the VM alone, plus small hourly charges for its disk and public IP address."
else
  echo "Could not read the live price. Check the estimate in the Azure portal. Expect cents per hour."
fi

echo
echo "== 6. The plan =="
echo "  Resource group : $RG (already made, empty, free)"
echo "  VM name        : $VM"
echo "  Region         : $LOC"
echo "  Size           : $VMSIZE"
echo "  Image          : Ubuntu 22.04 LTS"
echo "  Ports open     : 22 (SSH, key login only) and 80 (the website)"
echo "  Azure's check  : passed for exactly these settings"
echo
flush_keyboard
read -r -p "Type yes to create these resources (billing starts). Anything else cancels: " ANSWER
if [ "$ANSWER" != "yes" ]; then
  echo "Cancelled. Nothing that costs money was created."
  echo "The empty resource group $RG is free. The next run reuses it. To remove it: bash infra/delete-azure-resources.sh"
  exit 0
fi

on_failure() {
  echo
  echo "Creation failed. Read the error above."
  echo "Clean up anything half-made with: bash infra/delete-azure-resources.sh"
}
trap on_failure ERR

echo
echo "== 7. Creating (this takes 1 to 3 minutes) =="
IP="$(vm_create "$LOC" "$VMSIZE" --query publicIpAddress --output tsv)"
az vm open-port --resource-group "$RG" --name "$VM" --port 80 --output none
trap - ERR

echo
echo "Done. Your VM's public IP address is: $IP"
echo "Write it down. Next, from the formflow folder:"
echo "  scp deploy/vm-setup.sh $ADMIN_USER@$IP:/tmp/vm-setup.sh"
echo "  ssh $ADMIN_USER@$IP 'bash /tmp/vm-setup.sh'"
echo "When you are completely finished with the project, delete everything with:"
echo "  bash infra/delete-azure-resources.sh"

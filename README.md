#### VMware
Scripts for VMware - vCenter - vSphere

This script connects to multiple vCenter servers, retrieves inventory data for ESXi hosts and VMs, and generates CSV and HTML reports of the findings.

#### How to deploy it
1. Install PowerCLI if you haven't already:
   Install-Module VMware.PowerCLI -Scope CurrentUser
2. Replace the three sample vCenter names in $VCenters with your actual vCenter FQDNs.
3. Set $OutputRoot to a local directory or an approved administrative file share.
4. Save and run the script:
   .\Enterprise-vSphere-ServerLocator.ps1
5. At each prompt, enter the appropriate username and password for that vCenter. Use the username format accepted by that environment, such as DOMAIN\username, a UPN, or administrator@vsphere.local.
6. Open C:\Reports\Enterprise-vSphere\Latest\Enterprise-ServerLocator-Latest.html to search your enterprise inventory.

# APIM shared policies (DEV first)

This repo uses **Azure APIOps Publisher v7.0.2**, not Bicep, to create or update three policy fragments and the service-level global policy in an **existing** APIM instance. Existing API repositories and their Classic Release pipelines are unchanged.

## Add the real source XML first

The actual policy XML **is not included** in this package because it was not supplied. Add your approved existing XML to these four locations:

```
global/policy.xml
policyFragments/apim-log-incoming-requests/policy.xml
policyFragments/apim-log-policy-error/policy.xml
policyFragments/apim-log-custom-rejection/policy.xml
```

`global/policy.xml` must contain the **complete existing global policy** with the two new references (apim-log-incoming-requests in inbound; apim-log-policy-error in on-error). The API/operation policies refer to apim-log-custom-rejection separately.

Each fragment XML must have a `<fragment>` root and valid APIM policy statements, with no `<base />`, nested include-fragment, or policy-section wrappers. The build script checks XML well-formedness and these invariants but cannot validate runtime APIM policy expressions.

## Configure before enabling deploy

1. Put these scripts under `scripts/` and `azure-pipelines.yml` at repo root.
2. Replace `REPLACE_WITH_DEV_VARIABLE_GROUP` in YAML with the exact *YAML-authorized* Dev variable group containing `targetSubscriptionId`, `targetResourceGroup`, and `targetApimName`.
3. Replace the `devServiceConnection` default with your existing, authorized Dev Azure Resource Manager service connection name.
4. Create Azure DevOps environment `apim-dev-shared`, add Approvals & checks, and restrict pipeline permissions to this pipeline.
5. Restrict access to the service connection and variable group. Ensure the service identity can read and write policies/fragments on the existing APIM service.
6. Confirm no other pipeline also owns these resources. Keep your existing manual copy of the live Dev global policy available for recovery.
7. Manual `Run pipeline` with `deployToDev=false` compiles/validates/publishes only. Inspect artifacts; nothing is deployed.
8. When approved to proceed, run with `deployToDev=true`. The pipeline runs: Build → DeployFragments → DeployGlobalPolicy, with the same protected environment applied to each deployment job.
9. After deployment, compare live XML with desired XML and run API smoke tests, especially CORS, known rejections, on-error logging, and policy inheritance. Use existing API releases only after shared resources are verified.

## Artifacts created at build time

```
shared-apim-artifacts/
  fragments/policyFragments/<fragment-id>/policyFragmentInformation.json
  global/policy.xml
```

The `fragments/` and `global/` directories are **different APIOps publish roots**. Publisher v7.0.2 is called separately on each. `COMMIT_ID` is explicitly cleared by the deployment script to publish the complete isolated root. The Publisher is the only process that **writes** these APIM resources; Azure CLI in other scripts is read-only except for selecting the target subscription.

## Failures and manual recovery

- Build errors make no Azure changes.
- Fragment publication failure blocks global publication, but partial fragment updates can remain; inspect and restore them if necessary.
- **No automatic rollback is provided**. Coordinate manual restoration of changed resources using a reviewed previous artifact or a controlled APIM management procedure. APIOps Publisher can republish the prior artifact, but it does not delete newly created resources merely because they are absent from the previous artifact when `COMMIT_ID` is unset.
- Do not rerun API pipelines or approve the global stage if resource verification or business tests fail.

## Security and versioning

- Publisher binary is pinned to `v7.0.2`, matching the existing API release, but downloading it at run time still carries supply-chain risk. The deployment script supports `-ExpectedPublisherSha256` for a verified binary hash; populate it through an approved mechanism before production use.
- The service account needs APIM configuration permissions. Avoid broad subscription-level Contributor when a narrower scope/role is possible.
- APIOps publisher XML/JSON artifact format and environment variables: https://github.com/Azure/apiops/blob/v7.0.2/docs/apiops/3-apimTools/apiops-2-2-tools-publisher.md
- Microsoft fragment documentation: https://learn.microsoft.com/azure/api-management/policy-fragments

## Not included

This package intentionally does not invent your actual global policy, fragment expressions, variable-group name, service connection name, or API test calls. Runtime smoke tests and manual rollback must be reviewed before production promotion.

## Manual policy copy

This revision intentionally has no backup stage and does not publish backup artifacts. The operator has confirmed they already maintain a copy of the current global policy. If deployment fails after fragments are updated, recovery is manual.

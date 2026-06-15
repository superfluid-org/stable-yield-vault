# DEPLOYMENTS LOGS

## SYNC VAULT rc0

```shell
forge script script/sync/DeploySync.s.sol:DeploySync --rpc-url $BASE_MAINNET_RPC_URL --account TEST_IN_PROD_DEPLOYER --broadcast --verify

[⠊] Compiling...
No files changed, compilation skipped
Enter keystore password:
Script ran successfully.

== Logs ==
  
  ===> DEPLOYMENT CONFIGURATION
   --- Treasury                      : 0xdc36265ca4505021250F02d3b711Dd9e9F23aD3D
   --- Underlying Asset              : 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
   --- Yield Asset                   : 0xD04383398dD2426297da660F9CCA3d439AF9ce1b
   --- External Vault                : 0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9
   --- Fund Operator                 : 0xB9337958009Fc5b320844FE34F9eb58D8018837C
   --- Fund Admin                    : 0xdc36265ca4505021250F02d3b711Dd9e9F23aD3D
   --- Initial Era Stable Yield Rate : 300
   --- Guaranteed Flow Duration      : 172800
   --- Share Name                    : SYV v0 Share
   --- Share Symbol                  : SYVV0
  
  ===> STARTING STRATEGY DEPLOYMENT :
   --- Chain ID          :    8453
   --- Deployer address  :    0xdc36265ca4505021250F02d3b711Dd9e9F23aD3D
  
  
  ===> DEPLOYMENT RESULTS
   --- Sync Fund Manager    : 0xC858EecF902E87c475B8531B51c5aa9956cAA277
   --- Sync Vault           : 0xdbf03CA61f951adc2081FB3BbcCb50E222B0af78
  

## Setting up 1 EVM.

==========================

Chain 8453

Estimated gas price: 0.0107875 gwei

Estimated total gas used for script: 6643989

Estimated amount required: 0.0000716720313375 ETH

==========================

##### base
✅  [Success] Hash: 0x89fedb6c91925d7bc93e21be2f0a8b0e06ecebbcca4f00389ccd3e88fdd797ba
Contract Address: 0xdbf03CA61f951adc2081FB3BbcCb50E222B0af78
Block: 47359600
Paid: 0.0000295785292875 ETH (5110761 gas * 0.0057875 gwei)

✅ Sequence #1 on base | Total Paid: 0.0000295785292875 ETH (5110761 gas * avg 0.0057875 gwei)
                                                                                                                                                                                                                                                                                   

==========================

ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.
```
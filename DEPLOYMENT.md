# DEPLOYMENTS LOGS

## SYNC VAULT final

Date: 26th June 2026
Operator: 0xPilou

```shell
forge script script/sync/DeploySync.s.sol:DeploySync --rpc-url $BASE_MAINNET_RPC_URL --account SUP_DEPLOYER --broadcast --verify

[⠊] Compiling...
No files changed, compilation skipped
Enter keystore password:
Script ran successfully.

== Logs ==
  
  ===> DEPLOYMENT CONFIGURATION
   --- Treasury                      : 0xac808840f02c47C05507f48165d2222FF28EF4e1
   --- Underlying Asset              : 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
   --- Yield Asset                   : 0xD04383398dD2426297da660F9CCA3d439AF9ce1b
   --- External Vault                : 0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9
   --- Fund Operator                 : 0xB9337958009Fc5b320844FE34F9eb58D8018837C
   --- Fund Admin                    : 0x4396c45Ac5910Dab4d27f74fe678932a51f33a4d
   --- Initial Era Stable Yield Rate : 300
   --- Guaranteed Flow Duration      : 172800
   --- Share Name                    : SuperVault Technical Demo Share
   --- Share Symbol                  : SVTD
  
  ===> STARTING STRATEGY DEPLOYMENT :
   --- Chain ID          :    8453
   --- Deployer address  :    0x011E5Ee334F9af11c631B362f1E0cbab4E15642a
  
  
  ===> DEPLOYMENT RESULTS
   --- Sync Fund Manager    : 0x904103dfE7231e2534e0Be29E6086CB0FF7d76bd
   --- Sync Vault           : 0x8C60503C0353ED12c3Eebc3036BF033A3BbB95Aa
   --- Sync Deposit Macro   : 0xA2175966fD97356C9ADb72ECC40875BC02Fa110b
  

## Setting up 1 EVM.

==========================

Chain 8453

Estimated gas price: 0.088279264 gwei

Estimated total gas used for script: 9519287

Estimated amount required: 0.000840355650164768 ETH

==========================

##### base
✅  [Success] Hash: 0xbfa5bc597113bf02ac41927a9195387492e2e0cb62798578dd82e8e4252f93b3
Contract Address: 0x8C60503C0353ED12c3Eebc3036BF033A3BbB95Aa
Block: 47845670
Paid: 0.000245446593772124 ETH (5513372 gas * 0.044518417 gwei)


##### base
✅  [Success] Hash: 0xd4112651c42d012d200409d8a7632f3b082dc2c4968ea8b2f4e766a5c787284a
Contract Address: 0xA2175966fD97356C9ADb72ECC40875BC02Fa110b
Block: 47845670
Paid: 0.000080540805744469 ETH (1809157 gas * 0.044518417 gwei)

✅ Sequence #1 on base | Total Paid: 0.000325987399516593 ETH (7322529 gas * avg 0.044518417 gwei)
                                                                                                                                                                                                                                                                                                        

==========================

ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.
```

## SYNC VAULT rc3 

Date: 25th June 2026
Operator: 0xPilou

```shell
forge script script/sync/DeploySync.s.sol:DeploySync --rpc-url $BASE_MAINNET_RPC_URL --account TEST_IN_PROD_DEPLOYER --broadcast --verify

[⠊] Compiling...
No files changed, compilation skipped
Warning: Detected artifacts built from source files that no longer exist. Run `forge clean` to make sure builds are in sync with project files.
 - /Users/pierrelouvel/_dev/superfluid/SFFDN/_poc/poc-stable-yield-vault/test/vault/sync/SyncVaultPausable.t.sol
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
   --- Initial Era Stable Yield Rate : 350
   --- Guaranteed Flow Duration      : 172800
   --- Share Name                    : SYV v3 Share
   --- Share Symbol                  : SYVV3
  
  ===> STARTING STRATEGY DEPLOYMENT :
   --- Chain ID          :    8453
   --- Deployer address  :    0xdc36265ca4505021250F02d3b711Dd9e9F23aD3D
  
  
  ===> DEPLOYMENT RESULTS
   --- Sync Fund Manager    : 0x89143240C593DDBF5dE7B5d14cfa57FD914604ce
   --- Sync Vault           : 0x29A4b75fE007E0541b3f6F0e72978f074FDe4105
   --- Sync Deposit Macro   : 0x27Fe058660716613a85708f10901b71B21595f27
  

## Setting up 1 EVM.

==========================

Chain 8453

Estimated gas price: 0.010749998 gwei

Estimated total gas used for script: 9519006

Estimated amount required: 0.000102329295461988 ETH

==========================

##### base
✅  [Success] Hash: 0xd13c6eb359c43eedef2ead3dcd6bbcbda14444813130c9fd2c01e420e39844e6
Contract Address: 0x29A4b75fE007E0541b3f6F0e72978f074FDe4105
Block: 47794049
Paid: 0.000031700635973688 ETH (5513156 gas * 0.005749998 gwei)


##### base
✅  [Success] Hash: 0x4e20ecfaf06b4e4c58ee55e1e4485a18ab38076c82713051e1691dad7a4095c8
Contract Address: 0x27Fe058660716613a85708f10901b71B21595f27
Block: 47794049
Paid: 0.000010402649131686 ETH (1809157 gas * 0.005749998 gwei)

✅ Sequence #1 on base | Total Paid: 0.000042103285105374 ETH (7322313 gas * avg 0.005749998 gwei)
                                                                                                                                                                                                                                                                                         

==========================

ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.
```

## SYNC VAULT rc2

Date: 22nd June 2026
Operator: 0xPilou

```shell
forge script script/sync/DeploySync.s.sol:DeploySync --rpc-url $BASE_MAINNET_RPC_URL --account TEST_IN_PROD_DEPLOYER --broadcast --verify

[⠊] Compiling...
[⠰] Compiling 3 files with Solc 0.8.34
[⠔] Solc 0.8.34 finished in 1.30s
Compiler run successful!
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
   --- Share Name                    : SYV v2 Share
   --- Share Symbol                  : SYVV2
  
  ===> STARTING STRATEGY DEPLOYMENT :
   --- Chain ID          :    8453
   --- Deployer address  :    0xdc36265ca4505021250F02d3b711Dd9e9F23aD3D
  
  
  ===> DEPLOYMENT RESULTS
   --- Sync Fund Manager    : 0x118cb1956A38cE1D3F6587A6F04a47aB032fD92d
   --- Sync Vault           : 0x21c4D7420f59D0A09592EB2683C6dbf55D8BF714
   --- Sync Deposit Macro   : 0x63fb8623D4E6e9f9040185D5013528EdC50D62Cb
  

## Setting up 1 EVM.

==========================

Chain 8453

Estimated gas price: 0.01075 gwei

Estimated total gas used for script: 9668084

Estimated amount required: 0.000103931903 ETH

==========================

##### base
✅  [Success] Hash: 0xd856e9388c9963c9bb26261542e56d676963a4de72225a372bee3374ef98c24f
Contract Address: 0x21c4D7420f59D0A09592EB2683C6dbf55D8BF714
Block: 47662310
Paid: 0.0000323601605 ETH (5627854 gas * 0.00575 gwei)


##### base
✅  [Success] Hash: 0x2b1216992c6ac3f24d241975613a67000e3f5c269e73aada43b5229b3197356c
Contract Address: 0x63fb8623D4E6e9f9040185D5013528EdC50D62Cb
Block: 47662310
Paid: 0.0000104025205 ETH (1809134 gas * 0.00575 gwei)

✅ Sequence #1 on base | Total Paid: 0.000042762681 ETH (7436988 gas * avg 0.00575 gwei)
                                                                                                                                                                                                                                                                                   

==========================

ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.
```


## SYNC VAULT rc1

Date: 19th June 2026
Operator: 0xPilou

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
   --- Sync Fund Manager    : 0x4565dEdf153428bc18eF2E0FA442999BE0611183
   --- Sync Vault           : 0xCd5c66174a8eD2B1e1dDba4Da293F62C80baEF03
   --- Sync Deposit Macro   : 0xda309852424bf9c75E40FB9b3B89E5941bfF2553
  

## Setting up 1 EVM.

==========================

Chain 8453

Estimated gas price: 0.0105 gwei

Estimated total gas used for script: 8969246

Estimated amount required: 0.000094177083 ETH

==========================

##### base
✅  [Success] Hash: 0x47efad1f58bc8724294fe46f1c8aa3744015e316e8f5d3333678245e545e32c9
Contract Address: 0xCd5c66174a8eD2B1e1dDba4Da293F62C80baEF03
Block: 47534910
Paid: 0.0000308553465 ETH (5610063 gas * 0.0055 gwei)


##### base
✅  [Success] Hash: 0xd78746ec5db2f6a8efdbdd773390095b896b4ca0b43308eb6593dd1956adb215
Contract Address: 0xda309852424bf9c75E40FB9b3B89E5941bfF2553
Block: 47534910
Paid: 0.000007091469 ETH (1289358 gas * 0.0055 gwei)

✅ Sequence #1 on base | Total Paid: 0.0000379468155 ETH (6899421 gas * avg 0.0055 gwei)
                                                                                                                                                                                                                                                                                   

==========================

ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.
```

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
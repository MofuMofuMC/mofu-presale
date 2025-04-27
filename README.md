



aptos move deploy-object --address-name mint-nft --profile roy

aptos move run --function-id 0x72e5ef01545c65f029c5ae91f595f83b31e64ff86ec3377cb446ec4152acbec1::signature_verifier::mint --profile roy

aptos account fund-with-faucet --account 0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8 --profile roy
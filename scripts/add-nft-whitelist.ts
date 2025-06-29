import {
	AccountAddress,
	Aptos,
	AptosConfig,
	type ClientConfig,
	Hex,
	Network,
	U256,
} from "@aptos-labs/ts-sdk";
import { getAccount } from "./config";

const PRESALE_CONTRACT_ADDRESS = process.env.MODULE_ADDRESS;
async function main() {
	const config = new AptosConfig({
		network: Network.TESTNET,
		// clientConfig,
	});

	const aptos = new Aptos(config);

	const account = getAccount();

	const txn = await aptos.transaction.build.simple({
		sender: account.accountAddress,
		data: {
			function:
				`${PRESALE_CONTRACT_ADDRESS}::presale::add_to_nft_whitelist`,
			typeArguments: [],
			functionArguments: [
				AccountAddress.from("0x541fdf47900d49433e94b588e34f7d0e4fc7f7faa092caef43c8ddf1890df707")
				// AccountAddress.from("0x30ff8dca978a711b19730eb767a79377023390899e5c3b07c7e6e245a4998874")
			],
		},
	});

	const committedTxn = await aptos.signAndSubmitTransaction({
		signer: account,
		transaction: txn,
	});

	await aptos.waitForTransaction({ transactionHash: committedTxn.hash });
	console.log(`Committed transaction: ${committedTxn.hash}`);
}

main()
	.then(() => {})
	.catch((error) => {
		console.error("Error:", error);
	});

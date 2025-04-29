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

function byteString(str: string): Uint8Array {
	const encoder = new TextEncoder();
	return encoder.encode(str);
}

async function main() {
	const clientConfig: ClientConfig = {
		API_KEY: "AG-FVEWZQTCTWH16J4DJMZOZCDP9NNN3MVM",
	};

	const config = new AptosConfig({
		network: Network.TESTNET,
		clientConfig,
	});

	const aptos = new Aptos(config);

	const account = getAccount();

	const txn = await aptos.transaction.build.simple({
		sender: account.accountAddress,
		data: {
			function:
				"0xc451769e267d5be6757642af06cf1666bceb99e24a6cd781a5a18cb46602b4b8::bridge::create_bridge_record",
			typeArguments: [],
			functionArguments: [
				byteString("0774B9C929630246ed78D24EF5a4547C47e86231"),
				AccountAddress.from(
					"0x131c061aa9f2523e743765ce278f83fd189ead4678f1583368fc886c08999b86",
				),
				new U256(41),
				0,
				2,
				Hex.fromHexString(
					"40f09ab570fa5a31d66651527ad483e9c553118bc6eb66af3947368424a641b49d1ff8ccc947deaf2810cc49d31428cca989b6d6167d89187da47ab5bb8e6f790e",
				).toUint8Array(),
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

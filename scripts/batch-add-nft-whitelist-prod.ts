import {
  AccountAddress,
  Aptos,
  AptosConfig,
  type ClientConfig,
  Network,
  type InputGenerateTransactionPayloadData,
} from "@aptos-labs/ts-sdk";
import { getAccount } from "./config";

import tokens from './token_ids.json'

const PRESALE_CONTRACT_ADDRESS = process.env.MODULE_ADDRESS;

async function main() {
  const config = new AptosConfig({
    network: Network.MAINNET,
    clientConfig: {
      API_KEY: "AG-5CL4LOBS2JK65GHXFNEKKGI33D128FJ3W",
    },
  });

  const aptos = new Aptos(config);
  const account = getAccount();

  // List of addresses to add to whitelist
  const addressesToWhitelist = tokens

  console.log(
    `Adding ${addressesToWhitelist.length} addresses to whitelist...`
  );

  // Create transaction payloads for each address
  const transactions: InputGenerateTransactionPayloadData[] =
    addressesToWhitelist.map((address, index) => {
      console.log(
        `Preparing transaction ${index + 1}/${
          addressesToWhitelist.length
        }: adding ${address}`
      );

      return {
        function: `${PRESALE_CONTRACT_ADDRESS}::presale::add_to_nft_whitelist`,
        typeArguments: [],
        functionArguments: [AccountAddress.from(address)],
      };
    });

  // Log transaction summary
  console.log(`\nPrepared ${transactions.length} whitelist additions`);

  try {
    // Sign and submit all transactions as a batch
    const batchResult = await aptos.transaction.batch.forSingleAccount({
      sender: account,
      data: transactions,
    });

    console.log("Batch whitelist addition successful");
    console.log(`Transaction details:`, JSON.stringify(batchResult, null, 2));
  } catch (error) {
    console.error("Error adding addresses to whitelist:", error);
  }
}

main()
  .then(() => {
    console.log("Batch whitelist addition process completed");
  })
  .catch((error) => {
    console.error("Error:", error);
  });

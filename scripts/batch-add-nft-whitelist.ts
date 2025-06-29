import {
  AccountAddress,
  Aptos,
  AptosConfig,
  type ClientConfig,
  Network,
  type InputGenerateTransactionPayloadData,
} from "@aptos-labs/ts-sdk";
import { getAccount } from "./config";

const PRESALE_CONTRACT_ADDRESS = process.env.MODULE_ADDRESS;

async function main() {
  const config = new AptosConfig({
    network: Network.TESTNET,
  });

  const aptos = new Aptos(config);
  const account = getAccount();

  // List of addresses to add to whitelist
  const addressesToWhitelist = [
    "0xac1766f751ea3f77551d3e5bdd6354fca91bf266a8483c38eeb938b9b2b24609",
    "0x66590bda0f5da2cf8688b7b38371e3dc3f13eb2763e2c4f088440580b7eb49c3",
    "0x541fdf47900d49433e94b588e34f7d0e4fc7f7faa092caef43c8ddf1890df707"
    // Add more addresses here
  ];

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

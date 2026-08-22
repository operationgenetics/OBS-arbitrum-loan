const { ethers } = require("ethers");
const { EthereumProvider } = require("@walletconnect/ethereum-provider");
const QRCode = require("qrcode-terminal");
const fs = require("fs");
const path = require("path");

const loanArtifactPath = path.join(__dirname, "out/ObscuraLoan.sol/ObscuraLoan.json");
const loanArtifact = JSON.parse(fs.readFileSync(loanArtifactPath, "utf8"));

async function main() {
    console.log("Initializing WalletConnect session...");

    const wcProvider = await EthereumProvider.init({
        projectId: "3a8170812b534d0ff9d794f19a901d64",
        chains: [42161],
        optionalChains: [42161, 1],
        rpcMap: {
            42161: "https://arb1.arbitrum.io/rpc"
        },
        metadata: {
            name: "Obscura Loan Deployment",
            description: "Deploying ObscuraLoan Smart Contract on Arbitrum One",
            url: "https://obscura.network",
            icons: ["https://avatars.githubusercontent.com/u/37784886"]
        },
        showQrModal: false
    });

    wcProvider.on("display_uri", (uri) => {
        console.log("\nScan this QR code in MetaMask Mobile (Scan icon at top right):\n");
        QRCode.generate(uri, { small: true }, (qr) => {
            console.log(qr);
        });
        console.log(`\nDirect URI Link:\n${uri}\n`);
    });

    console.log("Connecting to WalletConnect relay...");
    await wcProvider.connect();

    const provider = new ethers.BrowserProvider(wcProvider);
    const signer = await provider.getSigner();
    const deployerAddress = await signer.getAddress();

    console.log(`\nConnected Wallet: ${deployerAddress}`);
    console.log("Preparing deployment transaction for ObscuraLoan...");

    const factory = new ethers.ContractFactory(
        loanArtifact.abi,
        loanArtifact.bytecode.object,
        signer
    );

    // Note: Adjust constructor arguments (aiOracle address and initial PQC fingerprint/bytes) as needed for your deployment
    const aiOracleAddress = deployerAddress; 
    const initialPqcFingerprint = "0x0123456789abcdef0123456789abcdef";

    console.log("\nBroadcasting contract deployment... Confirm on your phone.");
    const contract = await factory.deploy(aiOracleAddress, initialPqcFingerprint);

    const deploymentTx = contract.deploymentTransaction();
    console.log(`Transaction Hash: ${deploymentTx.hash}`);

    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();

    console.log(`\n==========================================`);
    console.log(`Deployment Successful!`);
    console.log(`ObscuraLoan Address: ${contractAddress}`);
    console.log(`==========================================\n`);

    process.exit(0);
}

main().catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
});

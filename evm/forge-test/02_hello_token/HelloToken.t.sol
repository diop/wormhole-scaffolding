// SPDX-License-Identifier: Apache 2
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {IWETH} from "../../src/interfaces/IWETH.sol";

import {WormholeSimulator} from "wormhole-solidity/WormholeSimulator.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../../src/02_hello_token/HelloToken.sol";
import "../../src/02_hello_token/HelloTokenStructs.sol";

/**
 * @title A Test Suite for the EVM HelloToken Contracts
 */
contract HelloTokenTest is Test {
    // guardian private key for simulated signing of Wormhole messages
    uint256 guardianSigner;

    // contract instances
    IWETH WETH;
    IWormhole wormhole;
    ITokenBridge bridge;
    WormholeSimulator public wormholeSimulator;
    HelloToken public helloTokenSource;
    HelloToken public helloTokenTarget;

    /**
     * @notice Sets up the wormholeSimulator contracts and deploys HelloToken
     * contracts before each test is executed.
     */
    function setUp() public {
        // verify that we're using the correct fork (AVAX mainnet in this case)
        require(block.chainid == vm.envUint("TESTING_FORK_CHAINID"), "wrong evm");

        // this will be used to sign Wormhole messages
        guardianSigner = uint256(vm.envBytes32("TESTING_DEVNET_GUARDIAN"));

        // set up Wormhole using Wormhole existing on AVAX mainnet
        wormholeSimulator = new WormholeSimulator(
            vm.envAddress("TESTING_WORMHOLE_ADDRESS"),
            guardianSigner
        );

        // we may need to interact with Wormhole throughout the test
        wormhole = wormholeSimulator.wormhole();

        // verify Wormhole state from fork
        require(
            wormhole.chainId() == uint16(vm.envUint("TESTING_WORMHOLE_CHAINID")),
            "wrong chainId"
        );
        require(
            wormhole.messageFee() == vm.envUint("TESTING_WORMHOLE_MESSAGE_FEE"),
            "wrong messageFee"
        );
        require(
            wormhole.getCurrentGuardianSetIndex() == uint32(vm.envUint("TESTING_WORMHOLE_GUARDIAN_SET_INDEX")),
            "wrong guardian set index"
        );

        // instantiate WETH interface
        WETH = IWETH(vm.envAddress("TESTING_WETH_ADDRESS"));

        // instantiate TokenBridge interface
        bridge = ITokenBridge(vm.envAddress("TESTING_BRIDGE_ADDRESS"));

        // relayer fee and precision
        uint32 feePrecision = 1e6;
        uint32 relayerFee = 1000; // 1 basis point

        // initialize "source chain" HelloToken contract
        helloTokenSource = new HelloToken(
            address(wormhole),
            vm.envAddress("TESTING_BRIDGE_ADDRESS"),
            wormhole.chainId(),
            uint8(1), // wormhole finality
            feePrecision,
            relayerFee
        );

        // initialize "target chain" HelloToken contract
        helloTokenTarget = new HelloToken(
            address(wormhole),
            vm.envAddress("TESTING_BRIDGE_ADDRESS"),
            uint8(2), // bogus chainId
            uint8(1), // wormhole finality
            feePrecision,
            relayerFee
        );

        // confirm that the source and target contract addresses are different
        assertTrue(address(helloTokenSource) != address(helloTokenTarget));
    }

    function wrapEth(uint256 amount) internal {
        WETH.deposit{value: amount}();
    }

    function addressToBytes32(address address_) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(address_)));
    }

    function normalizeAmount(uint256 amount, uint8 decimals) internal pure returns(uint256){
        if (decimals > 8) {
            amount /= 10 ** (decimals - 8);
        }
        return amount;
    }

    function deNormalizeAmount(uint256 amount, uint8 decimals) internal pure returns(uint256){
        if (decimals > 8) {
            amount *= 10 ** (decimals - 8);
        }
        return amount;
    }

    /**
     * @notice This test confirms that the contracts are able to serialize and deserialize
     * the HelloToken message correctly.
     */
    function testMessageDeserialization(
        bytes32 targetRecipient,
        uint32 relayerFee,
        bool isNative
    ) public {
        vm.assume(targetRecipient != bytes32(0));

        // encode the message by calling the encodePayload method
        bytes memory encodedMessage = helloTokenSource.encodePayload(
            HelloTokenStructs.HelloTokenMessage({
                payloadID: uint8(1),
                targetRecipient: targetRecipient,
                relayerFee: relayerFee,
                isNative: isNative
            })
        );

        // decode the message by calling the decodePayload method
        HelloTokenStructs.HelloTokenMessage memory results =
            helloTokenSource.decodePayload(encodedMessage);

        // verify the parsed output
        assertEq(results.payloadID, 1);
        assertEq(results.targetRecipient, targetRecipient);
    }

    /**
     * @notice This test confirms that decodePayload reverts when a message
     * has an unexpected payloadID.
     */
    function testIncorrectMessagePayload() public {
        // create garbage targetRecipient address
        bytes32 targetRecipient = bytes32(uint256(uint160(address(this))));

        // encode the message by calling the encodePayload method
        bytes memory encodedMessage = helloTokenSource.encodePayload(
            HelloTokenStructs.HelloTokenMessage({
                payloadID: uint8(2),
                targetRecipient: targetRecipient,
                relayerFee: 10000,
                isNative: false
            })
        );

        // expect a revert when trying to decode a message the wrong payloadID
        vm.expectRevert("invalid payloadID");
        helloTokenSource.decodePayload(encodedMessage);
    }

    /**
     * @notice This test confirms that decodePayload reverts when a message
     * is an unexpected length.
     */
    function testIncorrectMessageLength() public {
        // create garbage targetRecipient address
        bytes32 targetRecipient = bytes32(uint256(uint160(address(this))));

        // encode the message by calling the encodePayload method
        bytes memory encodedMessage = helloTokenSource.encodePayload(
            HelloTokenStructs.HelloTokenMessage({
                payloadID: uint8(1),
                targetRecipient: targetRecipient,
                relayerFee: 10000,
                isNative: false
            })
        );

        // add some bytes to the encodedMessage
        encodedMessage = abi.encodePacked(
            encodedMessage,
            uint256(42000)
        );

        // expect a revert when trying to decode a message an invalid length
        vm.expectRevert("invalid payload length");
        helloTokenSource.decodePayload(encodedMessage);
    }

    /**
     * @notice This test confirms that the owner can correctly register a foreign emitter
     * with the HelloToken contracts.
     */
    function testRegisterEmitter() public {
        // cache the new emitter info
        uint16 newEmitterChainId = helloTokenTarget.chainId();
        bytes32 newEmitterAddress = bytes32(uint256(uint160(address(helloTokenTarget))));

        // register the emitter with the owner's wallet
        helloTokenSource.registerEmitter(newEmitterChainId, newEmitterAddress);

        // verify that the contract state was updated correctly
        bytes32 emitterInContractState = helloTokenSource.getRegisteredEmitter(
            helloTokenTarget.chainId()
        );
        assertEq(emitterInContractState, newEmitterAddress);
    }

    /**
     * @notice This test confirms that ONLY the owner can register a foreign emitter
     * with the HelloToken contracts.
     */
    function testRegisterEmitterNotOwner() public {
        // cache the new emitter info
        uint16 newEmitterChainId = helloTokenTarget.chainId();
        bytes32 newEmitterAddress = bytes32(uint256(uint160(address(helloTokenTarget))));

        // prank the caller address to something different than the owner's address
        vm.prank(address(wormholeSimulator));

        // expect the registerEmitter call to revert
        vm.expectRevert("caller not the owner");
        helloTokenSource.registerEmitter(newEmitterChainId, newEmitterAddress);
    }

    /**
     * @notice This test confirms that the `sendTokensWithPayload` method correctly sends the
     * a token with an addtional payload.
     */
    function testSendTokensWithPayload(
        uint256 amount,
        address targetRecipient
    ) public {
        vm.assume(amount > 1e8 && amount < type(uint96).max);
        vm.assume(targetRecipient != address(0));

        // wrap some ether
        wrapEth(amount);

        // register the emitter on the source contract
        helloTokenSource.registerEmitter(
            helloTokenTarget.chainId(),
            bytes32(uint256(uint160(address(helloTokenTarget))))
        );

        // start listening to events
        vm.recordLogs();

        // approve the HelloToken contract to spend WETH
        SafeERC20.safeApprove(
            IERC20(address(WETH)),
            address(helloTokenSource),
            amount
        );

        // call the source HelloToken contract to transfer tokens
        uint64 sequence = helloTokenSource.sendTokensWithPayload(
            address(WETH),
            amount,
            helloTokenTarget.chainId(),
            0, // opt out of batching
            targetRecipient
        );

        // record the emitted Wormhole message
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length > 0, "no events recorded");

        // find published wormhole messages from log
        Vm.Log[] memory publishedMessages =
            wormholeSimulator.fetchWormholeMessageFromLog(logs, 1);

        // simulate signing the Wormhole message
        // NOTE: in the wormhole-sdk, signed Wormhole messages are referred to as signed VAAs
        bytes memory encodedMessage = wormholeSimulator.fetchSignedMessageFromLogs(
            publishedMessages[0],
            helloTokenSource.chainId(),
            address(helloTokenSource)
        );

        // parse and verify the message
        (
            IWormhole.VM memory wormholeMessage,
            bool valid,
            string memory reason
        ) = wormhole.parseAndVerifyVM(encodedMessage);
        require(valid, reason);

        // call the token bridge to parse the transferWithPayload
        ITokenBridge.TransferWithPayload memory transfer =
            bridge.parseTransferWithPayload(wormholeMessage.payload);

        // The TokenBridge normalizes the transfer amount to support
        // blockchains that don't support type uint256. We need to normalize the
        // amount we passed to the contract to compare the value against what
        // is encoded in the payload.
        assertEq(transfer.amount, normalizeAmount(amount, 18));

        // verify the remaining TransferWithPayload values
        assertEq(transfer.tokenAddress, addressToBytes32(address(WETH)));
        assertEq(transfer.tokenChain, helloTokenSource.chainId());
        assertEq(transfer.to, addressToBytes32(address(helloTokenTarget)));
        assertEq(transfer.toChain, helloTokenTarget.chainId());
        assertEq(transfer.fromAddress, addressToBytes32(address(helloTokenSource)));

        // verify VAA values
        assertEq(wormholeMessage.sequence, sequence);
        assertEq(wormholeMessage.nonce, 0); // batchID
        assertEq(wormholeMessage.consistencyLevel, helloTokenSource.wormholeFinality());

        // parse additional payload and verify the values
        HelloTokenStructs.HelloTokenMessage memory message =
            helloTokenTarget.decodePayload(transfer.payload);

        assertEq(message.payloadID, 1);
        assertEq(message.targetRecipient, addressToBytes32(targetRecipient));
        assertEq(message.relayerFee, helloTokenSource.relayerFee());
        assertEq(message.isNative, false);
    }

    /**
     * @notice This test confirms that the `sendTokensWithPayload` method reverts when
     * the `amount` is zero.
     * @dev vm.expectRevert fails to expect the correct revert string. This is a
     * known forge bug. The keyword `fail` is added to the test name so that
     * the forge test passes with any failure.
     */
    function testFailSendTokensWithPayloadAmountZero(
        address targetRecipient
    ) public {
        vm.assume(targetRecipient != address(0));

        uint256 amount = 0;

        // call `sendTokensWithPayload` should revert
        helloTokenSource.sendTokensWithPayload(
            address(WETH),
            amount,
            helloTokenTarget.chainId(),
            0, // opt out of batching
            targetRecipient
        );
    }

    /**
     * @notice This test confirms that the `sendTokensWithPayload` method reverts when
     * the `targetRecipient` is the zero address.
     * @dev vm.expectRevert fails to expect the correct revert string. This is a
     * known forge bug. The keyword `fail` is added to the test name so that
     * the forge test passes with any failure.
     */
    function testFailSendTokensWithPayloadInvalidRecipient(uint256 amount) public {
        vm.assume(amount > 1e8);

        // call `sendTokensWithPayload` should revert
        helloTokenTarget.sendTokensWithPayload(
            address(WETH),
            amount,
            helloTokenTarget.chainId(),
            0, // opt out of batching
            address(0)
        );
    }

    /**
     * @notice This test confirms that the `sendTokensWithPayload` method reverts when
     * the `token` is the zero address.
     * @dev vm.expectRevert fails to expect the correct revert string. This is a
     * known forge bug. The keyword `fail` is added to the test name so that
     * the forge test passes with any failure.
     */
    function testFailSendTokensWithPayloadInvalidToken(
        uint256 amount,
        address targetRecipient
    ) public {
        vm.assume(amount > 1e8);
        vm.assume(targetRecipient != address(0));

        // call `sendTokensWithPayload` should revert
        helloTokenTarget.sendTokensWithPayload(
            address(0),
            amount,
            helloTokenTarget.chainId(),
            0, // opt out of batching
            targetRecipient
        );
    }

    /**
     * @notice This test confirms that the `sendTokensWithPayload` method reverts when
     * the target chain does not have a registered emitter.
     * @dev vm.expectRevert fails to expect the correct revert string. This is a
     * known forge bug. The keyword `fail` is added to the test name so that
     * the forge test passes with any failure.
     */
    function testFailSendTokensWithPayloadInvalidTargetContract(
        uint256 amount,
        address targetRecipient,
        uint16 targetChain
    ) public {
        vm.assume(amount > 1e8);
        vm.assume(targetRecipient != address(0));
        vm.assume(targetChain != 0 && targetChain != helloTokenTarget.chainId());

        // call `sendTokensWithPayload` should revert
        helloTokenTarget.sendTokensWithPayload(
            address(WETH),
            amount,
            targetChain,
            0, // opt out of batching
            targetRecipient
        );
    }
}

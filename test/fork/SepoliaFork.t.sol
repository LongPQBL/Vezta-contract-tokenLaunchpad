// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";
import {PairAddress} from "../../contracts/libraries/PairAddress.sol";
import {IUniswapV2Factory, IUniswapV2Pair, IUniswapV2Router02} from "../../contracts/interfaces/IUniswapV2.sol";

/// @notice Runs against real Uniswap V2 on a Sepolia fork. Skipped unless SEPOLIA_RPC_URL is set.
contract SepoliaForkTest is Test {
    address internal constant ROUTER = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
    bytes32 internal constant INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
    }

    function test_Fork_InitCodeHashMatchesLivePairs() public view {
        IUniswapV2Factory uniFactory = IUniswapV2Factory(IUniswapV2Router02(ROUTER).factory());
        for (uint256 i; i < 3; ++i) {
            address pair = uniFactory.allPairs(i);
            address computed = PairAddress.compute(
                address(uniFactory), INIT_CODE_HASH, IUniswapV2Pair(pair).token0(), IUniswapV2Pair(pair).token1()
            );
            assertEq(computed, pair);
        }
    }

    function test_Fork_DeployScriptAndFullLifecycle() public {
        (VeztaLaunchToken curve, TokenFactory factory) = new Deploy().run();
        address weth = IUniswapV2Router02(ROUTER).WETH();
        (bool enabled, uint256 graduation) = curve.quotes(weth);
        assertTrue(enabled);
        assertEq(graduation, 0.4 ether);

        address creator = makeAddr("creator");
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        address token = factory.deployERC20Token{value: curve.createFee()}("Fork Test", "FORK", "ipfs://x", weth);

        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        curve.buyWithEth{value: 1 ether}(token, type(uint256).max, 1 ether);
        assertTrue(curve.getCurve(token).complete);

        curve.migrate(token);
        address pair = IUniswapV2Factory(curve.uniswapFactory()).getPair(token, weth);
        assertEq(pair, curve.getCurve(token).pair);
        assertApproxEqAbs(IERC20(weth).balanceOf(pair), 0.4 ether, 2);
        assertEq(IERC20(token).balanceOf(pair), 2e26);
    }
}

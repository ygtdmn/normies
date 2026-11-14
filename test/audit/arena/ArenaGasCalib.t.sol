// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { Vm } from "forge-std/src/Vm.sol";

contract CalibTarget {
    uint256 public x;
    mapping(uint256 => uint256) public m;

    function nop() external { }

    function burn(uint256 n) external {
        for (uint256 i; i < n; ++i) {
            m[i] = 1;
        }
    }

    function resetAndSet() external {
        // dirty-slot check: x was set non-zero in an earlier call
        x = x + 1;
    }
}

/// @notice Calibrates what vm.lastCallGas() reports, with and without --isolate.
contract ArenaGasCalibTest is Test {
    CalibTarget t;

    function setUp() public {
        t = new CalibTarget();
    }

    function test_calib_nop() public {
        t.nop();
        Vm.Gas memory g = vm.lastCallGas();
        emit log_named_uint("nop gasTotalUsed", g.gasTotalUsed);
        emit log_named_uint("nop gasLimit", g.gasLimit);
        t.nop{ gas: 100_000 }();
        g = vm.lastCallGas();
        emit log_named_uint("nop{gas:100k} gasTotalUsed", g.gasTotalUsed);
        emit log_named_uint("nop{gas:100k} gasLimit", g.gasLimit);
    }

    function test_calib_dirtySlot() public {
        t.resetAndSet();
        Vm.Gas memory g = vm.lastCallGas();
        emit log_named_uint("first x=x+1 (0->1)", g.gasTotalUsed);
        t.resetAndSet();
        g = vm.lastCallGas();
        emit log_named_uint("second x=x+1 (1->2)", g.gasTotalUsed);
        emit log_named_int("second refund", g.gasRefunded);
    }

    /// @dev 1,000 fresh slots is about 22.2M gas: must fail under an enforced 16,777,216 tx gas limit.
    function test_calib_control_over_cap() public {
        t.burn(1000);
        Vm.Gas memory g = vm.lastCallGas();
        emit log_named_uint("burn(1000) gasTotalUsed", g.gasTotalUsed);
    }

    function test_calib_explicit_gas_over_cap() public {
        t.burn{ gas: 30_000_000 }(1000);
        Vm.Gas memory g = vm.lastCallGas();
        emit log_named_uint("burn{gas:30M}(1000) gasTotalUsed", g.gasTotalUsed);
        emit log_named_uint("gasLimit", g.gasLimit);
    }
}

contract ArenaGasCalib2Test is Test {
    CalibTarget t;

    function setUp() public {
        t = new CalibTarget();
    }

    /// @dev Smallest {gas: g} at which a call succeeds, by binary search on a state snapshot.
    function _minGas(bytes memory data, uint256 lo, uint256 hi) internal returns (uint256) {
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(t).call{ gas: mid }(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
        return lo;
    }

    function test_calib_minGas() public {
        emit log_named_uint("min gas nop", _minGas(abi.encodeCall(t.nop, ()), 1, 1_000_000));
        emit log_named_uint("min gas burn(10)", _minGas(abi.encodeCall(t.burn, (10)), 1, 10_000_000));
        t.burn(10);
        emit log_named_uint("burn(10) gasTotalUsed", vm.lastCallGas().gasTotalUsed);
    }
}

/// @notice The effect behind I-10: vm.cool makes a slot cold again but keeps its "original value" from the start of
///         the test call, so a write to a slot the same test already changed is charged as a dirty write.
contract ArenaGasCalibCoolTest is Test {
    CalibTarget t;

    function setUp() public {
        t = new CalibTarget();
    }

    /// @dev Without --isolate: x is written (0 -> 1) inside this test, the target is cooled, then x is written again
    ///      (1 -> 2) and measured the way the existing Arena gas tests measure. A real transaction pays 2,100 (cold
    ///      read) + 2,900 (non-zero to non-zero write) = 5,000 for that write; here it pays 2,100 + 100.
    function test_calib_coolDoesNotResetOriginalValue() public {
        t.resetAndSet();
        vm.cool(address(t));
        uint256 before = gasleft();
        t.resetAndSet();
        uint256 used = before - gasleft();
        emit log_named_uint("x = x + 1 (1 -> 2) after vm.cool, measured with gasleft()", used);
        emit log_named_uint("same call, vm.lastCallGas().gasTotalUsed", vm.lastCallGas().gasTotalUsed);
    }

    /// @dev The same write as the only call of a transaction (run with --isolate to see the true cost; subtract the
    ///      21,000 base and 64 calldata gas).
    function test_calib_sameWriteAlone() public {
        t.resetAndSet();
        t.resetAndSet();
        emit log_named_uint("x = x + 1 (1 -> 2), vm.lastCallGas().gasTotalUsed", vm.lastCallGas().gasTotalUsed);
    }
}

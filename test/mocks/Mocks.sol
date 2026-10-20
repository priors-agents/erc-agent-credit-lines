// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @notice An ERC-721-shaped identity registry reduced to what the tests need: mint, transfer, ownerOf.
contract MockRegistry {
    mapping(uint256 => address) private _owners;

    function mint(address to, uint256 id) external {
        _owners[id] = to;
    }

    function transfer(uint256 id, address to) external {
        require(_owners[id] == msg.sender, "not owner");
        _owners[id] = to;
    }

    function ownerOf(uint256 id) external view returns (address o) {
        o = _owners[id];
        require(o != address(0), "no token");
    }
}

/// @notice A plain ERC-20 with a public mint.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

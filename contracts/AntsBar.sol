pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";


contract AntsBar is ERC20("AntsBar", "xANTS"){
    using SafeMath for uint256;
    IERC20 public ants;

    constructor(IERC20 _ants) public {
        ants = _ants;
    }

    // Enter the bar. Pay some ANTSs. Earn some shares.
    function enter(uint256 _amount) public {
        uint256 totalAnts = ants.balanceOf(address(this));
        uint256 totalShares = totalSupply();
        if (totalShares == 0 || totalAnts == 0) {
            _mint(msg.sender, _amount);
        } else {
            uint256 what = _amount.mul(totalShares).div(totalAnts);
            _mint(msg.sender, what);
        }
        ants.transferFrom(msg.sender, address(this), _amount);
    }

    // Leave the bar. Claim back your ANTSs.
    function leave(uint256 _share) public {
        uint256 totalShares = totalSupply();
        uint256 what = _share.mul(ants.balanceOf(address(this))).div(totalShares);
        _burn(msg.sender, _share);
        ants.transfer(msg.sender, what);
    }
}
/*
*   v1.0.0-rc4
*   proxy contract for WeCross
*   main entrance of all contract call
*/

pragma solidity >=0.5.0 <0.6.0;
import "./CNSPrecompiled.sol";
pragma experimental ABIEncoderV2;

contract Proxy {

    event WarningMsg(bytes msg);

    // per step of transaction
    struct TransactionStep {
        string path;
        uint256 timestamp;
        address contractAddress;
        string func;
        bytes args;
    }

    // information of transaction
    struct TransactionInfo {
        address[] contractAddresses;
        uint8 status;    // 0-Start 1-Commit 2-Rollback
        uint256 startTimestamp;
        uint256 commitTimestamp;
        uint256 rollbackTimestamp;
        uint256[] seqs;   // sequence of each step
        uint256 stepNum;  // step number
    }

    struct ContractInfo {
        bool locked;     // isolation control, read-committed
        string path;
        string transactionID;
    }

    mapping(address => ContractInfo) lockedContracts;

    mapping(string => TransactionInfo) transactions;      // key: transactionID

    mapping(string => TransactionStep) transactionSteps;  // key: transactionID||seq

    /*
    * record all tansactionIDs
    * head: point to the current tansaction to be checked
    * tail: point to the next position for added tansaction
    */
    uint256 head = 0;
    uint256 tail = 0;
    string[] tansactionQueue;

    string constant revertFlag = "_revert";
    string constant nullFlag = "null";
    byte   constant separator = '.';
    uint256 constant addressLen = 42;
    uint256 maxStep = 32;
    string[] pathCache;

    CNSPrecompiled cns;
    constructor() public {
        cns = CNSPrecompiled(0x1004);
    }

    function getMaxStep() public view
    returns(uint256)
    {
        return maxStep;
    }

    function setMaxStep(uint256 _maxStep) public
    {
        maxStep = _maxStep;
    }

    function addPath(string memory _path) public
    {
        pathCache.push(_path);
    }

    function getPaths() public view
    returns (string[] memory)
    {
        return pathCache;
    }

    function deletePathCache() public
    {
        pathCache.length = 0;
    }

    // constant call
    function constantCall(string memory _transactionID, string memory _path, string memory _func, bytes memory _args) public
    returns(bytes memory)
    {
        address addr = getAddressByPath(_path);

        if(sameString(_transactionID, "0")) {
             return callContract(addr, _func, _args);
        }

        if(!isExistedTransaction(_transactionID)) {
            emit WarningMsg("transaction id not found");
        }

        if(!sameString(lockedContracts[addr].transactionID, _transactionID)) {
            emit WarningMsg("unregistered contract address");
        }

        return callContract(addr, _func, _args);
    }

    // non-constant call
    function sendTransaction(string memory _transactionID, uint256 _seq, string memory _path, string memory _func, bytes memory _args) public
    returns(bytes memory)
    {
        address addr = getAddressByPath(_path);

        if(sameString(_transactionID, "0")) {
            if(lockedContracts[addr].locked) {
                revert("contract is locked by unfinished transaction");
            }
             return callContract(addr, _func, _args);
        }

        if(!isExistedTransaction(_transactionID)) {
            revert("transaction id not found");
        }

        if(transactions[_transactionID].status == 1) {
            revert("has committed");
        }

        if(transactions[_transactionID].status == 2) {
            revert("has rolledback");
        }

        if(!sameString(lockedContracts[addr].transactionID, _transactionID)) {
            revert("unregistered contract");
        }

        if(!sameString(lockedContracts[addr].path, _path)) {
            revert("unregistered path");
        }


        // recode step
        transactionSteps[getTransactionStepKey(_transactionID, _seq)] = TransactionStep(
            _path,
            now,
            addr,
            _func,
            _args
        );

        // recode seq
        if(isNewStep(_transactionID, _seq)) {
            uint256 num = transactions[_transactionID].stepNum;
            transactions[_transactionID].seqs[num] = _seq;
            transactions[_transactionID].stepNum = num + 1;
        }

        return callContract(addr, _func, _args);
    }

    /*
    * result: 0-success, 1-transaction_existed, 2-contract_conflict
    */
    function startTransaction(string memory _transactionID, string[] memory _paths) public
    returns(uint256 result)
    {
        if(isExistedTransaction(_transactionID)) {
            emit WarningMsg("transaction existed");
            return 1;
        }

        uint256 len = _paths.length;
        address[] memory contracts = new address[](len);

        // recode ACL
        for(uint256 i = 0; i < len; i++) {
            address addr = getAddressByPath(_paths[i]);
            contracts[i] = addr;

            if(lockedContracts[addr].locked) {
                emit WarningMsg("contract conflict");
                return 2;
            }
            lockedContracts[addr].locked = true;
            lockedContracts[addr].path = _paths[i];
            lockedContracts[addr].transactionID = _transactionID;
        }

        uint256[] memory temp = new uint256[](maxStep);
        // recode transaction
        transactions[_transactionID] = TransactionInfo(
            contracts,
            0,
            now,
            0,
            0,
            temp,
            0
        );

        addTransaction(_transactionID);
        return 0;
    }

    /*
    * result: 0-success, 1-transaction_not_found, 2-rolledback
    */
    function commitTransaction(string memory _transactionID) public
    returns(uint256 result)
    {
        if(!isExistedTransaction(_transactionID)) {
            emit WarningMsg("transaction id not found");
            return 1;
        }

        // has commited
        if(transactions[_transactionID].status == 1) {
            return 0;
        }

        if(transactions[_transactionID].status == 2) {
            emit WarningMsg("has rolledback");
            return 2;
        }

        transactions[_transactionID].commitTimestamp = now;
        transactions[_transactionID].status = 1;

        deleteLockedContracts(_transactionID);

        return 0;
    }

    /*
    * result: 0-success, 1-transaction_not_found, 2-commited, 3-not_yet
    */
    function rollbackTransaction(string memory _transactionID) public
    returns(uint256)
    {
        if(!isExistedTransaction(_transactionID)) {
            emit WarningMsg("transaction id not found");
            return 1;
        }


        if(transactions[_transactionID].status == 1) {
            emit WarningMsg("has commited");
            return 2;
        }

        // has rolledback
        if(transactions[_transactionID].status == 2) {
            emit WarningMsg("has rolledback");
            return 0;
        }

        uint256 stepNum = transactions[_transactionID].stepNum;
        for(uint256 i = stepNum - 1; i >= 0; i--) {
            uint256 seq = transactions[_transactionID].seqs[i];
            string memory key = getTransactionStepKey(_transactionID, seq);

            string memory abiStr = transactionSteps[key].func;
            address contractAddress = transactionSteps[key].contractAddress;
            bytes memory args = transactionSteps[key].args;

            // call revert function
           callContract(contractAddress, getRevertFunc(abiStr, revertFlag), args);

           if(i == 0) {
               break;
           }
        }

        transactions[_transactionID].rollbackTimestamp = now;
        transactions[_transactionID].status = 2;

        deleteLockedContracts(_transactionID);

        return 0;
    }

    /*
    * result with json form
    * "null": transaction not found
    * example:
    {
    	"transactionID": "1",
    	"status": 1,
    	"startTimestamp": "123",
    	"commitTimestamp": "456",
    	"rollbackTimestamp": "789",
    	"transactionSteps": [{
            	"seq": 0,
    			"contract": "0x12",
    			"path": "a.b.c",
    			"timestamp": "123",
    			"func": "test1(string)",
    			"args": "aaa"
    		},
    		{
    		    "seq": 1,
    			"contract": "0x12",
    			"path": "a.b.c",
    			"timestamp": "123",
    			"func": "test2(string)",
    			"args": "bbb"
    		}
    	]
    }
    */
    function getTransactionInfo(string memory _transactionID) public view
    returns(string memory)
    {
        if(!isExistedTransaction(_transactionID)) {
            return nullFlag;
        }

        return string(abi.encodePacked("{\"transactionID\":", "\"", _transactionID, "\",",
            "\"status\":", uint256ToString(transactions[_transactionID].status), ",",
            "\"startTimestamp\":", "\"", uint256ToString(transactions[_transactionID].startTimestamp), "\",",
            "\"commitTimestamp\":", "\"", uint256ToString(transactions[_transactionID].commitTimestamp), "\",",
            "\"rollbackTimestamp\":", "\"", uint256ToString(transactions[_transactionID].rollbackTimestamp), "\",",
            transactionStepArrayToJson(_transactionID, transactions[_transactionID].seqs, transactions[_transactionID].stepNum), "}")
            );
    }

    // called by router to check transaction status
    function getLatestTransactionInfo() public view
    returns(string memory)
    {
        string memory transactionID;

        if(head == tail) {
            return nullFlag;
        } else {
            transactionID = (tansactionQueue[uint(head)]);
        }

        return getTransactionInfo(transactionID);
    }

     // internal call
    function callContract(address _contractAddress, string memory _sig, bytes memory _args) internal
    returns(bytes memory result)
    {
        bytes memory sig = abi.encodeWithSignature(_sig);
        bool success;
        (success, result) = address(_contractAddress).call(abi.encodePacked(sig, _args));
        require(success);
    }

    // called by router to delete finished transaction
    function deleteTransaction(string memory _transactionID) public
    returns (uint256)
    {
        if(head == tail || !sameString(tansactionQueue[head], _transactionID)) {
            return 1;
        }
        head++;
        return 0;
    }

    function addTransaction(string memory _transactionID) internal
    {
        tail++;
        tansactionQueue.push(_transactionID);
    }

    // retrive address from CNS
    function getAddressByPath(string memory _path) internal view
    returns (address)
    {
        string memory name = getNameByPath(_path);
        string memory strJson = cns.selectByName(name);

        bytes memory str = bytes(strJson);
        uint256 len = str.length;
        bytes memory inverseStr = new bytes(len);

        // get inverse str
        for(uint256 i = 0; i < len; i++) {
            inverseStr[i] = str[len - i -1];
        }
        uint256 index = len - kmpAlgorithm(inverseStr, bytes("\"sserdda\""));

        bytes memory addr = new bytes(addressLen);
        uint256 start = 0;
        for(uint256 i = index; i < len; i++) {
            if(str[i] == byte('0') && str[i+1] == byte('x')) {
                start = i;
                break;
            }
        }

        for(uint256 i = 0; i < addressLen; i++) {
            addr[i] = str[start + i];
        }

        return bytesToAddress(addr);
    }

    // input must be a valid path like "zone.chain.resource"
    function getNameByPath(string memory _path) internal pure
    returns (string memory)
    {
        bytes memory path = bytes(_path);
        uint256 len = path.length;
        uint256 nameLen = 0;
        uint256 index = 0;
        for(uint256 i = len - 1; i > 0; i--) {
            if(path[i] == separator) {
                index = i + 1;
                break;
            } else {
                nameLen++;
            }
        }

        bytes memory name = new bytes(nameLen);
        for(uint256 i = 0; i < nameLen; i++) {
            name[i] = path[index++];
        }

        return string(name);
    }

    // "transactionSteps": [{"seq": 0, "contract": "0x12","path": "a.b.c","timestamp": "123","func": "test1(string)","args": "aaa"},{"seq": 1, "contract": "0x12","path": "a.b.c","timestamp": "123","func": "test2(string)","args": "bbb"}]
    function transactionStepArrayToJson(string memory _transactionID, uint256[] memory _seqs, uint256 _len) internal view
    returns(string memory result)
    {
        if(_len == 0) {
            return "\"transactionSteps\":[]";
        }

        result = string(abi.encodePacked("\"transactionSteps\":[", transactionStepToJson(transactionSteps[getTransactionStepKey(_transactionID, _seqs[0])], _seqs[0])));
        for(uint256 i = 1; i < _len; i++) {
                    result = string(abi.encodePacked(result, ",", transactionStepToJson(transactionSteps[getTransactionStepKey(_transactionID, _seqs[i])], _seqs[i])));
        }

        return string(abi.encodePacked(result, "]"));
    }

    // {"seq": 0, "contract": "0x12","path": "a.b.c","timestamp": "123","func": "test2(string)","args": "bbb"}
    function transactionStepToJson(TransactionStep memory _step, uint256 _seq) internal pure
    returns(string memory)
    {
        return string(abi.encodePacked("{\"seq\":", uint256ToString(_seq), ",",
                "\"contract\":", "\"", addressToString(_step.contractAddress), "\",",
                "\"path\":", "\"", _step.path, "\",",
                "\"timestamp\":", "\"", uint256ToString(_step.timestamp), "\",",
                "\"func\":", "\"", _step.func, "\",",
                "\"args\":", "\"", bytesToHexString(_step.args), "\"}")
                );
    }

    function isExistedTransaction(string memory _transactionID) internal view
    returns (bool)
    {
        return transactions[_transactionID].startTimestamp != 0;
    }

    function isNewStep(string memory _transactionID, uint256 _seq) internal view
    returns(bool)
    {
        for(uint256 i = 0; i < transactions[_transactionID].stepNum; i++) {
            if(transactions[_transactionID].seqs[i] == _seq) {
                return false;
            }
        }
        return true;
    }

    function deleteLockedContracts(string memory _transactionID) internal
    {
        uint256 len = transactions[_transactionID].contractAddresses.length;
        for(uint256 i = 0; i < len; i++) {
            address contractAddress = transactions[_transactionID].contractAddresses[i];
            delete lockedContracts[contractAddress];
        }
    }

    function getTransactionStepKey(string memory _transactionID, uint256 _seq) internal pure
    returns(string memory)
    {
        return string(abi.encodePacked(_transactionID, uint256ToString(_seq)));
    }

    // famous algorithm for finding substring
    function kmpAlgorithm(bytes memory _str, bytes memory _target) internal pure
    returns (uint256)
    {
        uint256 strLen = _str.length;
        uint256 tarLen = _target.length;
        uint256[] memory nextArray = new uint256[](strLen);

        // init nextArray
        next(_target, nextArray);

        uint256 i = 1;
        uint256 j = 1;

        while (i <= strLen && j <= tarLen) {
            if (j == 0 || _str[i-1] == _target[j-1]) {
                i++;
                j++;
            }
            else{
                j = nextArray[j];
            }
        }

        if ( j > tarLen) {
            return i - tarLen;
        }

        return 0;
    }

    function next(bytes memory _target, uint256[] memory _next) internal pure
    {
        uint256 i = 1;
        _next[1] = 0;
        uint256 j = 0;

        uint256 len = _target.length;
        while (i < len) {
            if (j == 0 || _target[i-1] == _target[j-1]) {
                i++;
                j++;
                if (_target[i-1] != _target[j-1]) {
                   _next[i] = j;
                }
                else{
                    _next[i] = _next[j];
                }
            }else{
                j = _next[j];
            }
        }
    }

    // func(string,uint256) => func_flag(string,uint256)
    function getRevertFunc(string memory _func, string memory _revertFlag) internal pure
    returns(string memory)
    {
        bytes memory funcBytes = bytes(_func);
        bytes memory flagBytes = bytes(_revertFlag);
        uint256 funcLen = funcBytes.length;
        uint256 flagLen = flagBytes.length;
        bytes memory newFunc = new bytes(funcLen + flagLen);

        byte c = byte('(');
        uint256 index = 0;
        uint256 point = 0;

        for(uint256 i = 0; i < funcLen; i++) {
            if(funcBytes[i] != c) {
                newFunc[index++] = funcBytes[i];
            } else {
                point = i;
                break;
            }
        }

        for(uint256 i = 0; i < flagLen; i++) {
            newFunc[index++] = flagBytes[i];
        }

        for(uint256 i = point; i < funcLen; i++) {
            newFunc[index++] = funcBytes[i];
        }

        return string(newFunc);
    }

    function sameString(string memory _str1, string memory _str2) internal pure
    returns (bool)
    {
        return keccak256(abi.encodePacked(_str1)) == keccak256(abi.encodePacked(_str2));
    }

    function hexStringToBytes(string memory _hexStr) internal pure
    returns (bytes memory)
    {
        bytes memory bts = bytes(_hexStr);
        require(bts.length%2 == 0);
        bytes memory result = new bytes(bts.length/2);
        uint len = bts.length/2;
        for (uint i = 0; i < len; ++i) {
            result[i] = byte(fromHexChar(uint8(bts[2*i])) * 16 +
                fromHexChar(uint8(bts[2*i+1])));
        }
        return result;
    }

    function fromHexChar(uint8 _char) internal pure
    returns (uint8)
    {
        if (byte(_char) >= byte('0') && byte(_char) <= byte('9')) {
            return _char - uint8(byte('0'));
        }
        if (byte(_char) >= byte('a') && byte(_char) <= byte('f')) {
            return 10 + _char - uint8(byte('a'));
        }
        if (byte(_char) >= byte('A') && byte(_char) <= byte('F')) {
            return 10 + _char - uint8(byte('A'));
        }
    }

    function uint256ToString(uint256 _value) internal pure
    returns (string memory)
    {
        bytes32 result;
        if (_value == 0) {
            return "0";
        } else {
            while (_value > 0) {
                result = bytes32(uint(result) / (2 ** 8));
                result |= bytes32(((_value % 10) + 48) * 2 ** (8 * 31));
                _value /= 10;
            }
        }
        return bytes32ToString(result);
    }

    function bytes32ToString(bytes32 _bts32) internal pure
    returns (string memory)
    {

       bytes memory result = new bytes(_bts32.length);

       uint len = _bts32.length;
       for(uint i = 0; i < len; i++) {
           result[i] = _bts32[i];
       }

       return string(result);
    }

    function bytesToAddress(bytes memory _address) public pure
    returns (address)
    {
        uint160 result = 0;
        uint160 b1;
        uint160 b2;
        for (uint i = 2; i < 2 + 2 * 20; i += 2) {
            result *= 256;
            b1 = uint160(uint8(_address[i]));
            b2 = uint160(uint8(_address[i + 1]));
            if ((b1 >= 97) && (b1 <= 102)) {
                b1 -= 87;
            } else if ((b1 >= 65) && (b1 <= 70)) {
                b1 -= 55;
            } else if ((b1 >= 48) && (b1 <= 57)) {
            b1 -= 48;
            }

            if ((b2 >= 97) && (b2 <= 102)) {
                b2 -= 87;
            } else if ((b2 >= 65) && (b2 <= 70)) {
                b2 -= 55;
            } else if ((b2 >= 48) && (b2 <= 57)) {
                b2 -= 48;
            }
            result += (b1 * 16 + b2);
        }
        return address(result);
    }

    function addressToString(address _addr) internal pure
    returns (string memory)
    {
        bytes memory result = new bytes(40);
        for (uint i = 0; i < 20; i++) {
            byte temp = byte(uint8(uint(_addr) / (2 ** (8 * (19 - i)))));
            byte b1 = byte(uint8(temp) / 16);
            byte b2 = byte(uint8(temp) - 16 * uint8(b1));
            result[2 * i] = convert(b1);
            result[2 * i + 1] = convert(b2);
        }
        return string(abi.encodePacked("0x", string(result)));
    }

    function bytesToHexString(bytes memory _bts) internal pure
    returns (string memory result)
    {
        uint256 len = _bts.length;
        bytes memory s = new bytes(len * 2);
        for (uint256 i = 0; i < len; i++) {
            byte befor = byte(_bts[i]);
            byte high = byte(uint8(befor) / 16);
            byte low = byte(uint8(befor) - 16 * uint8(high));
            s[i*2] = convert(high);
            s[i*2+1] = convert(low);
        }
        result = string(s);
    }
    
    function convert(byte _b) internal pure
    returns (byte)
    {
        if (uint8(_b) < 10) {
            return byte(uint8(_b) + 0x30);
        } else {
            return byte(uint8(_b) + 0x57);
        }
    }
}

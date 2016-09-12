//
//  TransactionManager.swift
//
//  This file is covered by the LICENSE file in the root of this project.
//  Copyright (c) 2016 NEM
//

import Foundation

/**
    The transaction manager singleton used to perform all kinds of actions
    in relationship with a transaction. Use this managers available methods
    instead of writing your own logic.
 */
public class TransactionManager {
    
    // MARK: - Manager Properties
    
    /// The singleton for the transaction manager.
    public static let sharedInstance = TransactionManager()

    // MARK: - Public Manager Methods
    
    /**
        Signes the provided transaction and creates the corresponding
        request announce object that will get passed to the NIS to
        announce the transaction.
     
        - Parameter transaction: The transaction which should get signed.
        - Parameter account: The account with which the transaction should get signed.
     
        - Returns: The request announce object of the provided transaction that will get passed to the NIS to announce the transaction.
     */
    public func signTransaction(transaction: Transaction, account: Account) -> RequestAnnounce {
        
        var transactionByteArray = [UInt8]()
        var transactionByteArrayHexadecimal = String()
        var transactionSignatureByteArray = [UInt8]()
        var transactionSignatureByteArrayHexadecimal = String()

        let commonPartByteArray = generateCommonTransactionPart(forTransaction: transaction)
        var transactionDependentPartByteArray: [UInt8]!
        
        transactionByteArray += commonPartByteArray
        
        switch transaction.type {
        case .TransferTransaction:
            
            transactionDependentPartByteArray = generateTransferTransactionPart(forTransaction: transaction as! TransferTransaction)
            
            transactionByteArray += transactionDependentPartByteArray
            
        case .MultisigTransaction:
            
            let transferTransactionCommonPartByteArray = generateCommonTransactionPart(forTransaction: (transaction as! MultisigTransaction).innerTransaction as! TransferTransaction)
            transactionDependentPartByteArray = generateTransferTransactionPart(forTransaction: (transaction as! MultisigTransaction).innerTransaction as! TransferTransaction)
            
            let innerTransactionLengthByteArray: [UInt8] = String(Int64(transferTransactionCommonPartByteArray.count + transactionDependentPartByteArray.count), radix: 16).asByteArrayEndian(4)
            
            transactionByteArray += innerTransactionLengthByteArray
            transactionByteArray += transferTransactionCommonPartByteArray
            transactionByteArray += transactionDependentPartByteArray
            
        default:
            break
        }

        transactionSignatureByteArray = generateTransactionSignature(forTransactionWithData: transactionByteArray, signWithAccount: account)

        transactionByteArrayHexadecimal = transactionByteArray.toHexadecimalString()
        transactionSignatureByteArrayHexadecimal = transactionSignatureByteArray.toHexadecimalString()

        let requestAnnounce = RequestAnnounce(data: transactionByteArrayHexadecimal, signature: transactionSignatureByteArrayHexadecimal)
        
        return requestAnnounce!
    }
    
    /**
        Calculates the fee for the transaction with the provided transaction amount.
     
        - Parameter transactionAmount: The amount that will get transferred through the transactions.
     
        - Returns: The fee for the transaction as a double.
     */
    public func calculateFee(forTransactionWithAmount transactionAmount: Double) -> Double {
        
        var transactionFee = 0.0
        
        if transactionAmount < 20000 {
            transactionFee = 1.0
        } else if transactionAmount >= 250000.0 {
            transactionFee = 25.0
        } else {
            transactionFee = floor(transactionAmount / 10000)
        }
        
        return transactionFee
    }
    
    /**
        Calculates the fee for the transaction with the provided message.
     
        - Parameter transactionMessageByteArray: The message that will get sent with the transaction.
     
        - Returns: The fee for the transaction as a double.
     */
    public func calculateFee(forTransactionWithMessage transactionMessageByteArray: [UInt8]) -> Double {
        
        var transactionFee = 0.0
        
        if transactionMessageByteArray.count != 0 {
            transactionFee = ceil(Double(transactionMessageByteArray.count) / 32)
        }
        
        return transactionFee
    }
    
    /**
        Encrypts the provided message with the senders private key and the recipients
        public key.
     
        - Parameter messageByteArray: The message that should get encrypted as a byte array.
        - Parameter senderEncryptedPrivateKey: The encrypted private key of the sender.
        - Parameter recipientPublicKey: The public key of the recipient.
     
        - Returns: The encrypted message as a byte array.
     */
    public func encryptMessage(messageByteArray: [UInt8], senderEncryptedPrivateKey: String, recipientPublicKey: String) -> Array<UInt8> {
        
        let senderPrivateKey = AccountManager.sharedInstance.decryptPrivateKey(senderEncryptedPrivateKey)
        
        let saltData = NSData().generateRandomIV(32)
        var saltByteArray: Array<UInt8> = Array(UnsafeBufferPointer(start: UnsafePointer<UInt8>(saltData.bytes), count: saltData.length))
        
        var sharedSecretByteArray: [UInt8] = Array(count: 32, repeatedValue: 0)
        var senderPrivateKeyByteArray: Array<UInt8> = senderPrivateKey.asByteArrayEndian(32)
        var recipientPublicKeyByteArray: Array<UInt8> = recipientPublicKey.asByteArray()
        
        ed25519_key_exchange_nem(&sharedSecretByteArray, &recipientPublicKeyByteArray, &senderPrivateKeyByteArray, &saltByteArray)
        
        var messageByteArray = messageByteArray
        var messageData = NSData(bytes: &messageByteArray, length: messageByteArray.count)
        
        let ivData = NSData().generateRandomIV(16)
        let customizedIVByteArray: Array<UInt8> = Array(UnsafeBufferPointer(start: UnsafePointer<UInt8>(ivData.bytes), count: ivData.length))
        messageData = messageData.aesEncrypt(sharedSecretByteArray, iv: customizedIVByteArray)!
        var encryptedByteArray: Array<UInt8> = Array(count: messageData.length, repeatedValue: 0)
        messageData.getBytes(&encryptedByteArray, length: messageData.length)
        let encryptedMessageByteArray = saltByteArray + customizedIVByteArray + encryptedByteArray
        
        return encryptedMessageByteArray
    }
    
    /**
        Decrypts the provided encrypted message with the receivers private key and the senders public key.
     
        - Parameter encryptedMessageByteArray: The encrypted message that should get decrypted as a byte array.
        - Parameter recipientEncryptedPrivateKey: The encrypted private key of the recipient.
        - Parameter senderPublicKey: The public key of the sender.
     
        - Returns: The decrypted message as a string or nil if the message was empty.
     */
    public func decryptMessage(encryptedMessageByteArray: Array<UInt8>, recipientEncryptedPrivateKey: String, senderPublicKey: String) -> String? {
        
        let recipientPrivateKey = AccountManager.sharedInstance.decryptPrivateKey(recipientEncryptedPrivateKey)
        
        var saltByteArray: Array<UInt8> = Array(encryptedMessageByteArray[0..<32])
        let ivByteArray: Array<UInt8> = Array(encryptedMessageByteArray[32..<48])
        var encByteArray: Array<UInt8> = Array(encryptedMessageByteArray[48..<encryptedMessageByteArray.count])
        
        var recipientPrivateKeyByteArray: Array<UInt8> = recipientPrivateKey.asByteArrayEndian(32)
        var senderPublicKeyByteArray: Array<UInt8> = senderPublicKey.asByteArray()
        var sharedSecretByteArray: Array<UInt8> = Array(count: 32, repeatedValue: 0)
        
        ed25519_key_exchange_nem(&sharedSecretByteArray, &senderPublicKeyByteArray, &recipientPrivateKeyByteArray, &saltByteArray)
        
        var messageData: NSData? = NSData(bytes: &encByteArray, length: encByteArray.count)
        messageData = messageData?.aesDecrypt(sharedSecretByteArray, iv: ivByteArray)
        
        if messageData == nil {
            return nil
        }
        
        return NSString(data: messageData!, encoding: NSUTF8StringEncoding) as? String
    }

    /**
        Validates a hexidecimal string and checks if the hexadecimal string
        is made up of valid characters.
     
        - Parameter hexadecimalString: The hexadecimal string that should get validated.
     
        - Returns: A bool indicating whether the validation was succesful or not.
     */
    public func validateHexadecimalString(hexadecimalString: String) -> Bool {
        
        let regex: NSRegularExpression?
        do {
            regex = try NSRegularExpression(pattern: "^[0-9a-f]*$", options: .CaseInsensitive)
        } catch {
            regex = nil
        }
        
        let textCheckingResult = regex?.firstMatchInString(hexadecimalString, options: [], range: NSMakeRange(0, hexadecimalString.characters.count))
        
        if textCheckingResult == nil || textCheckingResult?.range.location == NSNotFound || hexadecimalString.characters.count % 2 != 0 {
            return false
        }
        
        return true
    }
    
    // MARK: - Private Manager Methods
    
    /**
        Generates the common part of the transaction data byte array.
     
        - Parameter transaction: The transaction for which the common part of the transaction data byte array should get generated.
     
        - Returns: The common part of the transaction data byte array.
     */
    private func generateCommonTransactionPart(forTransaction transaction: Transaction) -> [UInt8] {
        
        var commonPartByteArray = [UInt8]()
        
        var transactionTypeByteArray: [UInt8]!
        var transactionVersionByteArray: [UInt8]!
        var transactionTimeStampByteArray: [UInt8]!
        let transactionPublicKeyLengthByteArray: [UInt8] = [32, 0, 0, 0]
        var transactionSignerByteArray: [UInt8]!
        var transactionFeeByteArray: [UInt8]!
        var transactionDeadlineByteArray: [UInt8]!
        
        transactionTypeByteArray = String(Int64(transaction.type.rawValue), radix: 16).asByteArrayEndian(4)
        transactionVersionByteArray = [UInt8(transaction.version), 0, 0, network]
        transactionTimeStampByteArray = String(Int64(transaction.timeStamp), radix: 16).asByteArrayEndian(4)
        transactionSignerByteArray = transaction.signer.asByteArray()
        transactionFeeByteArray = String(transaction.fee, radix: 16).asByteArrayEndian(8)
        transactionDeadlineByteArray = String(Int64(transaction.deadline), radix: 16).asByteArrayEndian(4)
        
        commonPartByteArray += transactionTypeByteArray
        commonPartByteArray += transactionVersionByteArray
        commonPartByteArray += transactionTimeStampByteArray
        commonPartByteArray += transactionPublicKeyLengthByteArray
        commonPartByteArray += transactionSignerByteArray
        commonPartByteArray += transactionFeeByteArray
        commonPartByteArray += transactionDeadlineByteArray
        
        return commonPartByteArray
    }
    
    /**
        Generates the transaction dependent part of the transaction data byte
        array for a transfer transaction.
     
        - Parameter transaction: The transfer transaction for which the transaction dependent part of the transaction data byte array should get generated.
     
        - Returns: The transaction dependent part of the transaction data byte array for a transfer transaction.
     */
    private func generateTransferTransactionPart(forTransaction transaction: TransferTransaction) -> [UInt8] {
        
        var transactionDependentPartByteArray = [UInt8]()
        
        let transactionRecipientAddressLengthByteArray: [UInt8] = [40, 0, 0, 0]
        var transactionRecipientAddressByteArray: [UInt8]!
        var transactionAmountByteArray: [UInt8]!
        var transactionMessageFieldLengthByteArray: [UInt8]!
        
        transactionRecipientAddressByteArray = Array<UInt8>(transaction.recipient.utf8)
        transactionAmountByteArray = String(Int64(transaction.amount), radix: 16).asByteArrayEndian(8)
        
        transactionDependentPartByteArray += transactionRecipientAddressLengthByteArray
        transactionDependentPartByteArray += transactionRecipientAddressByteArray
        transactionDependentPartByteArray += transactionAmountByteArray
        
        if transaction.message?.payload != nil && transaction.message?.payload.count > 0 {
            
            var transactionMessageTypeByteArray: [UInt8]!
            var transactionMessagePayloadLengthByteArray: [UInt8]!
            var transactionMessagePayloadByteArray: [UInt8]!
            
            transactionMessageFieldLengthByteArray = String(transaction.message!.payload.count + 8, radix: 16).asByteArrayEndian(4)
            transactionMessageTypeByteArray = [UInt8(transaction.message!.type.rawValue), 0, 0, 0]
            transactionMessagePayloadLengthByteArray = String(transaction.message!.payload.count, radix: 16).asByteArrayEndian(4)
            transactionMessagePayloadByteArray = transaction.message!.payload
            
            transactionDependentPartByteArray += transactionMessageFieldLengthByteArray
            transactionDependentPartByteArray += transactionMessageTypeByteArray
            transactionDependentPartByteArray += transactionMessagePayloadLengthByteArray
            transactionDependentPartByteArray += transactionMessagePayloadByteArray
            
        } else {
            
            transactionMessageFieldLengthByteArray = [0, 0, 0, 0]
            
            transactionDependentPartByteArray += transactionMessageFieldLengthByteArray
        }
        
        return transactionDependentPartByteArray
    }
    
    /**
        Generates the signature for the provided transaction data with the provided account.
     
        - Parameter transactionDataByteArray: The transaction data byte array for which the signature should get generated.
        - Parameter account: The account with which the transaction data should get signed.
     
        - Returns: The transaction signature as a byte array.
     */
    private func generateTransactionSignature(forTransactionWithData transactionDataByteArray: [UInt8], signWithAccount account: Account) -> [UInt8] {
        
        let accountPrivateKey = AccountManager.sharedInstance.decryptPrivateKey(account.privateKey)
        let accountPublicKey = account.publicKey
        
        var transactionDataByteArray = transactionDataByteArray
        var accountPrivateKeyByteArray: [UInt8] = Array(accountPrivateKey.utf8)
        var accountPublicKeyByteArray: [UInt8] = Array(accountPublicKey.utf8)
        var transactionSignature: [UInt8] = Array(count: 64, repeatedValue: 0)
        
        Sign(&transactionSignature, &transactionDataByteArray, Int32(transactionDataByteArray.count), &accountPublicKeyByteArray, &accountPrivateKeyByteArray)
        
        return transactionSignature
    }
}

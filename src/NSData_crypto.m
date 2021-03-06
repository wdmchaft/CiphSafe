/*
 * Copyright � 2003,2006,2011, Bryan L Blackburn.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in
 *    the documentation and/or other materials provided with the
 *    distribution.
 *
 * 3. Neither the names Bryan L Blackburn, Withay.com, nor the names of
 *    any contributors may be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY BRYAN L BLACKBURN ``AS IS'' AND ANY
 * EXPRESSED OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 * OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
 * IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 */
/*
 * You need to have the OpenSSL header files (as well as the location of their
 * include directory given to Project Builder) for this to compile.  For it
 * to link, add /usr/lib/libcrypto.dylib and /usr/lib/libssl.dylib to the linked
 * frameworks.
 */
/* NSData_crypto.m */

#import "NSData_crypto.h"
#include <unistd.h>
#include <openssl/evp.h>


// Localized strings
#define NSDATA_CRYPTO_LOC_SETKEYLENFAIL NSLocalizedString(@"EVP_CIPHER_CTX_set_key_length failed", @"")
#define NSDATA_CRYPTO_LOC_IVBAD         NSLocalizedString(@"iv is %ld bytes, not 8", @"")


@implementation NSData (withay_crypto)

static BOOL cryptoLoggingEnabled = YES;

/*
 * Log the warning/error, if logging enabled
 */
+ (void) logCryptoMessage:(NSString *)format, ...
{
   if(cryptoLoggingEnabled)
   {
      va_list args;
      va_start(args, format);
      NSLogv([NSString stringWithFormat:@"NSData_crypto: %@\n", format], args);
      va_end(args);
   }
}


/*
 * Whether or not errors should be logged
 */
+ (void) setCryptoLogging:(BOOL)logEnabled
{
   cryptoLoggingEnabled = logEnabled;
}


/*
 * Pull out 'len' bytes from /dev/random, returning in a mutable data so
 * they can be overwritten later, if necessary
 */
+ (NSMutableData *) randomDataOfLength:(ssize_t)len
{
   NSMutableData *randomData = nil;
   ssize_t amtRead = 0;
   NSFileHandle *devRandom = [NSFileHandle fileHandleForReadingAtPath:@"/dev/random"];
   if(devRandom != nil)
   {
      randomData = [NSMutableData dataWithLength:len];
      while(amtRead < len)
      {
         /*
          * Here, we use read() instead of NSFileHandle's readDataOfLength:
          * because readDataOfLength: returns an NSData *, not NSMutableData *.
          */
         ssize_t oneRead = read([devRandom fileDescriptor],
                                [randomData mutableBytes],
                                len - amtRead);
         if(oneRead <= 0 && (errno != EINTR && errno != EAGAIN))
         {
            [NSData logCryptoMessage:NSLocalizedString(@"read() error in randomDataOfLength: %s (%d)", @""),
                                     strerror(errno),
                                     errno];
            randomData = nil;
            break;
         }
         amtRead += oneRead;
      }
      [devRandom closeFile];
   }
   else
      [NSData logCryptoMessage:NSLocalizedString(@"failed to open /dev/random", @"")];

   return randomData;
}


/* 
 * Encrypt the receiver's data with Blowfish (CBC mode) using the given
 * key and initialization vector; make sure iv is 8 bytes
 */
- (NSMutableData *) blowfishEncryptedDataWithKey:(NSData *)key iv:(NSData *)iv
{
   NSMutableData *encryptedData = nil;
   int finalLen = 0;
   if([iv length] == 8)
   {
      EVP_CIPHER_CTX cipherContext;
      if(EVP_EncryptInit(&cipherContext, EVP_bf_cbc(), NULL, [iv bytes]))
      {
         if(EVP_CIPHER_CTX_set_key_length(&cipherContext, [key length]))
         {
            if(EVP_EncryptInit(&cipherContext, NULL, [key bytes], NULL))
            {
               int encLen = [self length] + 8;   // Make sure we have enough space
               encryptedData = [NSMutableData dataWithLength:encLen];
               if(EVP_EncryptUpdate(&cipherContext,
                                    [encryptedData mutableBytes],
                                    &encLen,
                                    [self bytes],
                                    [self length]))
               {
                  finalLen = encLen;
                  encLen = [encryptedData length] - finalLen;
                  if(EVP_EncryptFinal(&cipherContext,
                                      [encryptedData mutableBytes] + finalLen,
                                      &encLen))
                  {
                     finalLen += encLen;
                     [encryptedData setLength:finalLen];
                  }
                  else
                     [NSData logCryptoMessage:NSLocalizedString(@"EVP_EncryptFinal() failed", @"")];
               }
               else
                  [NSData logCryptoMessage:NSLocalizedString(@"EVP_EncryptUpdate() failed", @"")];
            }
            else
               [NSData logCryptoMessage:NSLocalizedString(@"EVP_EncryptInit() failed (setting key)", @"")];
         }
         else
            [NSData logCryptoMessage:NSDATA_CRYPTO_LOC_SETKEYLENFAIL];
         EVP_CIPHER_CTX_cleanup(&cipherContext);
      }
      else
         [NSData logCryptoMessage:NSLocalizedString(@"EVP_EncryptInit() failed (initial)", @"")];
   }
   else
      [NSData logCryptoMessage:NSDATA_CRYPTO_LOC_IVBAD, (long) [iv length]];

   if(encryptedData != nil && [encryptedData length] != finalLen)
      encryptedData = nil;

   return encryptedData;
}


/* 
 * Dencrypt the receiver's data with Blowfish (CBC mode) using the given
 * key and initialization vector; make sure iv is 8 bytes
 */
- (NSMutableData *) blowfishDecryptedDataWithKey:(NSData *)key iv:(NSData *)iv
{
   NSMutableData *plainData = nil;
   int finalLen = 0;
   if([iv length] == 8)
   {
      EVP_CIPHER_CTX cipherContext;
      if(EVP_DecryptInit(&cipherContext, EVP_bf_cbc(), NULL, [iv bytes]))
      {
         if(EVP_CIPHER_CTX_set_key_length(&cipherContext, [key length]))
         {
            if(EVP_DecryptInit(&cipherContext, NULL, [key bytes], NULL))
            {
               int decLen = [self length] + 8;   // Make sure there's enough room
               plainData = [NSMutableData dataWithLength:decLen];
               if(EVP_DecryptUpdate(&cipherContext,
                                    [plainData mutableBytes],
                                    &decLen,
                                    [self bytes],
                                    [self length]))
               {
                  finalLen = decLen;
                  decLen = [plainData length] - finalLen;
                  if(EVP_DecryptFinal(&cipherContext,
                                      [plainData mutableBytes] + finalLen,
                                      &decLen))
                  {
                     finalLen += decLen;
                     [plainData setLength:finalLen];
                  }
                  else
                     [NSData logCryptoMessage:NSLocalizedString(@"EVP_DecryptFinal() failed", @"")];
               }
               else
                  [NSData logCryptoMessage:NSLocalizedString(@"EVP_DecryptUpdate() failed", @"")];
            }
            else
               [NSData logCryptoMessage:NSLocalizedString(@"EVP_DecryptInit() failed (setting key)", @"")];
         }
         else
            [NSData logCryptoMessage:NSDATA_CRYPTO_LOC_SETKEYLENFAIL];
         EVP_CIPHER_CTX_cleanup(&cipherContext);
      }
      else
         [NSData logCryptoMessage:NSLocalizedString(@"EVP_DecryptInit() failed (initial)", @"")];
   }
   else
      [NSData logCryptoMessage:NSDATA_CRYPTO_LOC_IVBAD, (long) [iv length]];

   if(plainData != nil && [plainData length] != finalLen)
      plainData = nil;

   return plainData;
}


/*
 * Return a SHA1 hash of the receiver's data
 */
- (NSMutableData *) SHA1Hash
{
   EVP_MD_CTX digestContext;
   EVP_DigestInit(&digestContext, EVP_sha1());
   int hashLen = EVP_MD_CTX_size(&digestContext);
   NSMutableData *hashValue = [NSMutableData dataWithLength:hashLen];
   EVP_DigestUpdate(&digestContext, [self bytes], [self length]);
   int writtenLen;
   EVP_DigestFinal(&digestContext, [hashValue mutableBytes], (unsigned int *) &writtenLen);
   if(writtenLen != hashLen)
   {
      [NSData logCryptoMessage:NSLocalizedString(@"EVP_DigestFinal wrote %d bytes, not the expected of %d",
                                                 @""),
                               writtenLen,
                               hashLen];
      hashValue = nil;
   }

   return hashValue;
}

@end

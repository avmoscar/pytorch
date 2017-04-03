/**
 * Copyright (c) 2017-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#include <chrono>
#include <functional>
#include <thread>
#include <vector>

#include "gloo/test/multiproc_test.h"

namespace gloo {
namespace test {
namespace {

// Test parameterization.
using Param = std::tuple<int, int, int>;

// Test fixture.
class TransportMultiProcTest : public MultiProcTest,
                               public ::testing::WithParamInterface<Param> {};

TEST_P(TransportMultiProcTest, IoErrors) {
  const auto processCount = std::get<0>(GetParam());
  const auto elementCount = std::get<1>(GetParam());
  const auto sleepMs = std::get<2>(GetParam());

  spawnAsync(processCount, [&](std::shared_ptr<Context> context) {
      std::vector<float> data;
      data.resize(elementCount);
      std::unique_ptr<transport::Buffer> sendBuffer;
      std::unique_ptr<transport::Buffer> recvBuffer;

      const auto& leftRank = (processCount + context->rank - 1) % processCount;
      auto& left = context->getPair(leftRank);
      left->setTimeout(50);
      recvBuffer = left->createRecvBuffer(
      0, data.data(), data.size() * sizeof(float));

      const auto& rightRank = (context->rank + 1) % processCount;
      auto& right = context->getPair(rightRank);
      right->setTimeout(50);
      sendBuffer = right->createSendBuffer(
      0, data.data(), data.size() * sizeof(float));

      while (true) {
        // Send value to the remote buffer
        sendBuffer->send(0, sizeof(float));
        sendBuffer->waitSend();

        // Wait for receive
        recvBuffer->waitRecv();
      }
    });
  if (sleepMs > 0) {
    // The test is specifically delaying before killing dependent processes.
    // The absolute time does not need to be deterministic.
    /* sleep override */
    std::this_thread::sleep_for(std::chrono::milliseconds(sleepMs));
  }

  // Kill one of the processes and wait for all to exit
  signalProcess(0, SIGKILL);
  wait();

  for (auto i = 0; i < processCount; i++) {
    if (i != 0) {
      const auto result = getResult(i);
      ASSERT_TRUE(WIFEXITED(result));
      ASSERT_EQ(kExitWithIoException, WEXITSTATUS(result));
    }
  }
}

TEST_P(TransportMultiProcTest, IoTimeouts) {
  const auto processCount = std::get<0>(GetParam());
  const auto elementCount = std::get<1>(GetParam());
  const auto sleepMs = std::get<2>(GetParam());

  spawnAsync(processCount, [&](std::shared_ptr<Context> context) {
      std::vector<float> data;
      data.resize(elementCount);
      std::unique_ptr<transport::Buffer> sendBuffer;
      std::unique_ptr<transport::Buffer> recvBuffer;

      const auto& leftRank = (processCount + context->rank - 1) % processCount;
      auto& left = context->getPair(leftRank);
      left->setTimeout(50);
      recvBuffer = left->createRecvBuffer(
      0, data.data(), data.size() * sizeof(float));

      const auto& rightRank = (context->rank + 1) % processCount;
      auto& right = context->getPair(rightRank);
      right->setTimeout(50);
      sendBuffer = right->createSendBuffer(
      0, data.data(), data.size() * sizeof(float));

      while (true) {
        // Send value to the remote buffer
        sendBuffer->send(0, sizeof(float));
        sendBuffer->waitSend();

        // Wait for receive
        recvBuffer->waitRecv();
      }
    });
  if (sleepMs > 0) {
    // The test is specifically delaying before killing dependent processes.
    // The absolute time does not need to be deterministic.
    /* sleep override */
    std::this_thread::sleep_for(std::chrono::milliseconds(sleepMs));
  }

  // Stop one process and wait for the others to exit
  signalProcess(0, SIGSTOP);
  for (auto i = 0; i < processCount; i++) {
    if (i != 0) {
      waitProcess(i);
      const auto result = getResult(i);
      ASSERT_TRUE(WIFEXITED(result));
      ASSERT_EQ(kExitWithIoException, WEXITSTATUS(result));
    }
  }

  // Kill the stopped process
  signalProcess(0, SIGKILL);
  waitProcess(0);
}

std::vector<int> genMemorySizes() {
  std::vector<int> v;
  v.push_back(sizeof(float));
  v.push_back(1000);
  return v;
}

INSTANTIATE_TEST_CASE_P(
    Transport,
    TransportMultiProcTest,
    ::testing::Combine(
        ::testing::Values(2, 3, 4),
        ::testing::ValuesIn(genMemorySizes()),
        ::testing::Values(0, 5, 50)));

} // namespace
} // namespace test
} // namespace gloo

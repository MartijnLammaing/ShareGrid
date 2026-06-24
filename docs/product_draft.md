## Sharegrid

## Description
A peer-to-peer compute sharing network to enable participants to use each other's local llm to solve problems, keep costs down, and prevent having to rely solely on cloud based solutions.

## What does it consist of
The project consists of 3 parts.

- LLMHost: A node that is running on someone's local machine, which is made available for a participant to use.
- LLMRouter: A server which the LLMHosts can connect to to be part of the network, and have participants be directed to.
- LLMUser: A local interface with which participants can ask questions to as if with a cloud provider (like opencode), but is being directed to LLMHosts behind the scenes.

## How does it work

First the LLMRouter needs to be started. This is the backbone of the network. At first there will be no LLMHosts registered, and no LLMUsers registed. LLMRouter waits for incoming requests.

When LLMHost is starts up, it connects with a LLMRouter (whose location configured). The LLMRouter hands back a key that allows the LLMHost to only accept calls that have authenticated through the LLMRouter first.

A LLMUser starts up its interface, which connects to the LLMRouter (whose location is configured). After handshaking, it receives a list of LLMHosts, with their metadata (location, LLM information, key).
The LLMUser can now choose which model it wants to use, set up a dedicated connection, and ask it a question.

When a LLMHost is unresponsive, or has been taken offline, the registry of connected LLMHosts in LLMRouter is updated.
When LLMUser isn't active anymore after a while, they are removed from the registry of connected LLMUsers, and will need to reconnect.

## LLMRouter

Contains a registry of connected LLMHosts, and a registry of connected LLMUsers.
It generates and hands out keys to the LLMHosts on connecting. It authenticates LLMUsers, and gives them information about available LLMHosts.

## LLMHost

Contains a LLM model running in a hardened Docker container with a port exposed for external access.
The docker container should not be able to leak information out to the host machine, nor should information from the host machine be able to leak into, or be accessed by the LLM or anything else running in the Docker container.

## LLMUser

Is basically just an interface to access the LLMHost and use its functionality, using the LLMRouter as a coordinator. The communication between LLMUser and LLMHost is a direct, private, dedicated and encrypted connection.

## Security considerations

Participating in a Sharegrid network should be as safe as possible for all participants, where anonymity and safety are of utmost importance. However, there might always be malicious actors trying to abuse the system.

Dangers that will need a solution:
- Malicious actors connecting to the LLMRouter presenting themselves as a LLMHost, but in reality don't have the hardened Docker features, or try to eavesdrop on the conversations between LLMUser and LLMHost.
- Communication between LLMUser and LLMHost should be encrypted. How to do this properly.
- LLMUsers could potentially give the LLMUser interface permission to read and write on their system. This should also be encapsulated in some way to prevent leaking of information, or performing malicious actions on LLMUser's machine.
- LLMHosts could be running an LLM that has been corrupted in some way to inject malware onto the LLMUser's machine
- When the LLMHost would need to access the internet for information, it could potentially be used as a proxy to retrieve illicit material, or do illegal actions on their behalf.
- In case that there are multiple sessions, or consequetive sessions running on the LLMHost, information between sessions must not be leaked.

## Problems that will need to be solved

- Concurrency issues: multiple LLMUsers want to use the same LLMHost. Can they share the resource, is it reserved for the duration of a session (with a session timeout).

## Timeline

# Phase 1
The first phase of this project should be to have a MVP, which has all security considerations under control, and could potentially be used on a local network, or on the internet between trusted participants.

Acceptance criteria of Phase 1:
- A LLMUser can ask a LLMHost a question safely and securely.
- A LLMHost can host safely and securely. The only thing they are sacrificing are Compute power and Disk and RAM space.

No internet access, and no bash execution, no existing IDE integration need to be added to this version. Plain CLI use suffices.
Only 1 LLMHost, LLMRouter and LLMUser for now.

# Phase 2
The second phase adds the capability to add your sharegrid network as a OpenCode cloud provider, and have it execute changes locally on the LLMUser machine.

Acceptance criteria of Phase 2:
- A LLMUser can add Sharegrid as a cloud provider on OpenCode.
- A connected LLMHost can send answers back to the LLMUser that can execute local file changes, or execute command line commands.
- A connected LLMHost can not go outside the bounds of the allowed perimeter.

# Phase 3
Adds the option for multiple LLMUsers and LLMHosts to enter the network. For now, a LLMHost will be reserved for 1 LLMUser per session.

Acceptance criteria of phase 3:
- A second LLMUser and LLMHost can be added.
- Once a LLMHost is in use, it can't be reached by another LLMUser.

> **Note:** Internet access for the LLM is handled via OpenCode's tool-call execution on the user machine, governed by OpenCode's `permission` setting. No host-side internet access is required.

# Next phases

From this point the system can be considered fully functional. There are a whole range of improvements that can be added which would make it even better.

- Adding multiple LLMRouters to the network, to enable load balancing.
- Enabling multiple LLMUsers on the same LLMHost, but separated session stores, to optimise resource usage.
- Adding a resource management system, which prevents participants from overusing, while not contributing
- Adding a request assessment module, which rates the conversations, their input as well as their responses, and rates the different used models on the effectivity of their answers. In a sense categorising which models should be used for which request. Could be extended by an automatic mode, which chooses the model automatically according to the question being posed.
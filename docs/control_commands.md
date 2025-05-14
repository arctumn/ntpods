# Control Commands

AACP uses opcode `9` for control commands. opcodes are 16 bit integers that specify the kind of action being done. The length of a control command is fixed to 7 bytes + 4 bytes header (`04 00 04 00`)

An AACP packet is formated as:

`04 00 04 00 [opcode, little endianness] [data]`

So, our control commands becomes

```
04 00 04 00 09 00 [identifier] [data1] [data2] [data3] [data4]
```

Bytes that are not used are set to `0x00`. From what I've observed, the `data3` and `data4` are never used, and hence always zero. And, the `data2` is usually used when the configuration can be different for the two buds: like, to change the long press mode. Or, if there can be two "state" variables for the same feature: like the Hearing Aid feature.

## Control Commands 
These commands

| Command identifier | Description | Format |
|--------------|---------------------|--------|
| 0x01 | Mic Mode | Single value (1 byte) |
| 0x05 | Button Send Mode | Single value (1 byte) |
| 0x12 | VoiceTrigger for Siri | Single Value (1 byte): `0x01` = enabled, `0x01` = disabled |
| 0x14 | SingleClickMode | Single value (1 byte) |
| 0x15 | DoubleClickMode | Single value (1 byte) |
| 0x16 | ClickHoldMode | Two values (2 bytes; First byte = right bud Second byte = for left): `0x01` = Noise control `0x05` = Siri |
| 0x17 | DoubleClickInterval | Single value (1 byte): 0x00 = Default, `0x01` = Slower, `0x02` = Slowest|
| 0x18 | ClickHoldInterval | Single value (1 byte): 0x00 = Default, `0x01` = Slower, `0x02` = Slowest|
| 0x1A | ListeningModeConfigs | Single value (1 byte): bitwise OR of the selected modes. Off mode = `0x01`, ANC=`0x02`, Transparency = 0x04, Adaptive = `0x08` |
| 0x1B | OneBudANCMode | Single value (1 byte): `0x01` = enabled, `0x02` = disabled |
| 0x1C | CrownRotationDirection | Single value (1 byte): `0x01` = reversed, `0x02` = default |
| 0x0D | ListeningMode | Single value (1 byte): 1 = Off, 2 = noise cancellation, 3 = transparency, 4 = adaptive |
| 0x1E | AutoAnswerMode | Single value (1 byte) |
| 0x1F | Chime Volume | Single value (1 byte): 0 to 100|
| 0x23 | VolumeSwipeInterval | Single value (1 byte): 0x00 = Default, `0x01` = Longer, `0x02` = Longest |
| 0x24 | Call Management Config | Single value (1 byte) |
| 0x25 | VolumeSwipeMode | Single value (1 byte): `0x01` = enabled, `0x02` = disabled |
| 0x26 | Adaptive Volume Config | Single value (1 byte): `0x01` = enabled, `0x02` = disabled |
| 0x27 | Software Mute config | Single value (1 byte) |
| 0x28 | Conversation Detect config | Single value (1 byte): `0x01` = enabled, `0x02` = disabled |
| 0x29 | SSL | Single value (1 byte) |
| 0x2C | Hearing Aid Enrolled and Hearing Aid Enabled | Two values (2 bytes; First byte - enrolled, Second byte = enabled): `0x01` = enabled, `0x02` = disabled |
| 0x2E | AutoANC Strength | Single value (1 byte): 0 to 100|
| 0x2F | HPS Gain Swipe | Single value (1 byte) |
| 0x30 | HRM enable/disable state | Single value (1 byte) |
| 0x31 | In Case Tone config | Single value (1 byte): `0x01` = enabled, `0x02` = disabled |
| 0x32 | Siri Multitone config | Single value (1 byte) |
| 0x33 | Hearing Assist config | Single value (1 byte): `0x01` = enabled, `0x02` = disabled |
| 0x34 | Allow Off Option for Listening Mode config | Single value (1 byte): `0x01` = enabled, `0x02` = disabled |


> [!NOTE]
> - These identifiers have been extracted from the macOS 15.4 Beta (24E5238a)'s bluetooth stack. 
> - I have already added the ranges of values a command takes that I know of. Feel free to experiemnt by sending the packets for which the range/values are not given here.

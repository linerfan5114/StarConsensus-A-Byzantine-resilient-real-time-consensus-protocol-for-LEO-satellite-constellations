-- StarConsensus: Byzantine-resilient real-time consensus for LEO constellations
-- Protocol: CRDT-Gossip + Hybrid Logical Clocks + Probabilistic Quorum
-- Latency: 3ms-45ms variable | Nodes: 100 | Topology: Dynamic LEO mesh

package Star_Consensus is

   type Real is digits 15;

   type Node_ID is range 1 .. 100;
   subtype Active_Nodes is Node_ID range 1 .. 100;

   type Milliseconds is new Real;
   type Seconds is new Real;
   type Epoch is range 0 .. 2**63 - 1;

   -- Hybrid Logical Clock: combines physical time with logical counter
   -- Survives GPS denial and clock drift between satellites
   type HLC_Timestamp is record
      Wall_Time : Seconds := 0.0;
      Logical   : Integer := 0;
      Node      : Node_ID := 1;
   end record;

   -- Decision states for consensus protocol
   type Decision_State is (Undecided, Proposing, Gathering, Decided, Committed, Expired);
   type Consensus_Round is range 0 .. 2**32 - 1;

   -- The consensus value: what satellites must agree on
   -- Example: target coordinates, maneuver timing, resource allocation
   type Consensus_Value is record
      Data_Type   : Integer range 0 .. 255 := 0;
      Priority    : Integer range 0 .. 10 := 0;
      Payload_X   : Real := 0.0;
      Payload_Y   : Real := 0.0;
      Payload_Z   : Real := 0.0;
      Payload_T   : Seconds := 0.0;
      Origin_Node : Node_ID := 1;
      Proposal_ID : Consensus_Round := 0;
   end record;

   -- Vector Clock: tracks causal relationships across distributed nodes
   type Vector_Clock is array (Node_ID) of Integer;

   -- CRDT Grow-Only Set: conflict-free mergeable set for membership
   type GSet_Element is record
      Node    : Node_ID;
      Round   : Consensus_Round;
      Value   : Consensus_Value;
      HLC     : HLC_Timestamp;
   end record;

   type GSet_Array is array (Positive range <>) of GSet_Element;
   type GSet (Max_Size : Natural) is record
      Elements : GSet_Array (1 .. Max_Size);
      Count    : Natural := 0;
   end record;

   -- Gossip message sent between satellites
   type Gossip_Message is record
      Sender_ID    : Node_ID;
      HLC          : HLC_Timestamp;
      Round        : Consensus_Round;
      Value        : Consensus_Value;
      VClock       : Vector_Clock;
      GSet_Payload : GSet (Max_Size => 20);
      Hop_Count    : Integer range 0 .. 255 := 0;
      TTL          : Integer range 0 .. 255 := 10;
      Is_Response  : Boolean := False;
      Request_ID   : Integer := 0;
   end record;

   -- Satellite state machine
   type Satellite_State is record
      My_ID         : Node_ID;
      HLC           : HLC_Timestamp;
      VClock        : Vector_Clock;
      Current_Round : Consensus_Round := 0;
      My_Value      : Consensus_Value;
      State         : Decision_State := Undecided;
      Known_Nodes   : GSet (Max_Size => 100);
      Decision      : Consensus_Value;
      Decided_At    : HLC_Timestamp;
      Gossip_Count  : Integer := 0;
      Merge_Count   : Integer := 0;
      Rounds_Completed : Integer := 0;
      Last_Gossip   : Seconds := 0.0;
      Is_Connected  : Boolean := True;
      In_Eclipse    : Boolean := False;
   end record;

   -- Network topology: latency matrix between satellite pairs
   type Latency_Matrix is array (Node_ID, Node_ID) of Milliseconds;

   -- Simulation configuration
   type Simulation_Config is record
      Num_Nodes       : Integer range 1 .. 100 := 100;
      Gossip_Fanout   : Integer range 1 .. 10 := 5;
      Gossip_Interval : Milliseconds := 100.0;
      Quorum_Threshold : Real range 0.0 .. 1.0 := 0.60;
      Eclipse_Probability : Real range 0.0 .. 1.0 := 0.15;
      Eclipse_Duration    : Seconds := 30.0;
      Max_Latency    : Milliseconds := 45.0;
      Min_Latency    : Milliseconds := 3.0;
      Simulation_Time : Seconds := 600.0;
      Decision_Timeout : Seconds := 30.0;
   end record;

   -- Consensus statistics
   type Consensus_Stats is record
      Total_Rounds      : Integer := 0;
      Successful_Rounds : Integer := 0;
      Failed_Rounds     : Integer := 0;
      Avg_Latency_To_Decision : Milliseconds := 0.0;
      Max_Latency_To_Decision : Milliseconds := 0.0;
      Avg_Gossip_Per_Decision : Real := 0.0;
      Eclipse_Events    : Integer := 0;
      Byzantine_Attempts : Integer := 0;
      Byzantine_Blocked  : Integer := 0;
   end record;

   -- Byzantine fault attempt record
   type Byzantine_Record is record
      Attacker_Node : Node_ID := 1;
      Round         : Consensus_Round := 0;
      Fake_Value    : Consensus_Value;
      Detected_At   : HLC_Timestamp;
      Blocked       : Boolean := False;
   end record;

   -- Helper functions
   function HLC_Compare (A, B : HLC_Timestamp) return Integer;
   function HLC_To_String (H : HLC_Timestamp) return String;
   function Consensus_Value_Equal (A, B : Consensus_Value) return Boolean;
   function Vector_Clock_Merge (A, B : Vector_Clock) return Vector_Clock;
   function GSet_Merge (A, B : GSet) return GSet;
   function GSet_Contains (S : GSet; ID : Node_ID; Round : Consensus_Round) return Boolean;
   function Calculate_Quorum_Size (Total : Integer; Threshold : Real) return Integer;
   function Generate_Random_Latency (Min, Max : Milliseconds) return Milliseconds;
   function Is_Eclipse (Probability : Real) return Boolean;

   -- Core protocol procedures
   procedure Init_Satellite
     (Sat    : out Satellite_State;
      ID     : Node_ID;
      Config : Simulation_Config);

   procedure Update_HLC
     (Sat       : in out Satellite_State;
      Received  : HLC_Timestamp);

   procedure Create_Gossip_Message
     (Sat : Satellite_State;
      Msg : out Gossip_Message;
      Config : Simulation_Config);

   procedure Process_Gossip_Message
     (Sat    : in out Satellite_State;
      Msg    : Gossip_Message;
      Config : Simulation_Config;
      Stats  : in out Consensus_Stats);

   function Check_Quorum
     (Sat    : Satellite_State;
      Config : Simulation_Config) return Boolean;

   function Has_Expired
     (Sat    : Satellite_State;
      Config : Simulation_Config) return Boolean;

   procedure Detect_Byzantine
     (Sat    : in out Satellite_State;
      Msg    : Gossip_Message;
      Record_Buf : in out Byzantine_Record;
      Stats  : in out Consensus_Stats);

   procedure Simulate_Network
     (Sats   : in out array (Node_ID) of Satellite_State;
      Config : Simulation_Config;
      Stats  : in out Consensus_Stats;
      Latency : Latency_Matrix);

end Star_Consensus;
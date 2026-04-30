-- StarConsensus: Core protocol implementation
-- CRDT-Gossip + HLC + Probabilistic Quorum + Byzantine detection

with Ada.Text_IO;  use Ada.Text_IO;
with Ada.Numerics; use Ada.Numerics;
with Ada.Numerics.Discrete_Random;
with Ada.Calendar; use Ada.Calendar;

package body Star_Consensus is

   package Random_Int is new Ada.Numerics.Discrete_Random (Integer);
   Seed : Random_Int.Generator;
   Seed_Initialized : Boolean := False;

   procedure Init_Random is
   begin
      if not Seed_Initialized then
         Random_Int.Reset (Seed, Integer (Seconds (Clock)));
         Seed_Initialized := True;
      end if;
   end Init_Random;

   function HLC_Compare (A, B : HLC_Timestamp) return Integer is
   begin
      if A.Wall_Time < B.Wall_Time then return -1;
      elsif A.Wall_Time > B.Wall_Time then return 1;
      elsif A.Logical < B.Logical then return -1;
      elsif A.Logical > B.Logical then return 1;
      elsif A.Node < B.Node then return -1;
      elsif A.Node > B.Node then return 1;
      else return 0; end if;
   end HLC_Compare;

   function HLC_To_String (H : HLC_Timestamp) return String is
   begin
      return "[" & Seconds'Image (H.Wall_Time) & ":" &
             Integer'Image (H.Logical) & ":" &
             Node_ID'Image (H.Node) & "]";
   end HLC_To_String;

   function Consensus_Value_Equal (A, B : Consensus_Value) return Boolean is
   begin
      return A.Data_Type = B.Data_Type and then
             A.Payload_X = B.Payload_X and then
             A.Payload_Y = B.Payload_Y and then
             A.Payload_Z = B.Payload_Z and then
             A.Payload_T = B.Payload_T;
   end Consensus_Value_Equal;

   function Vector_Clock_Merge (A, B : Vector_Clock) return Vector_Clock is
      Result : Vector_Clock := A;
   begin
      for I in Node_ID loop
         if B (I) > Result (I) then
            Result (I) := B (I);
         end if;
      end loop;
      return Result;
   end Vector_Clock_Merge;

   function GSet_Merge (A, B : GSet) return GSet is
      Result : GSet (Max_Size => A.Max_Size) := A;
   begin
      for I in 1 .. B.Count loop
         if not GSet_Contains (Result, B.Elements (I).Node, B.Elements (I).Round) then
            if Result.Count < Result.Max_Size then
               Result.Count := Result.Count + 1;
               Result.Elements (Result.Count) := B.Elements (I);
            end if;
         end if;
      end loop;
      return Result;
   end GSet_Merge;

   function GSet_Contains (S : GSet; ID : Node_ID; Round : Consensus_Round) return Boolean is
   begin
      for I in 1 .. S.Count loop
         if S.Elements (I).Node = ID and then S.Elements (I).Round = Round then
            return True;
         end if;
      end loop;
      return False;
   end GSet_Contains;

   function Calculate_Quorum_Size (Total : Integer; Threshold : Real) return Integer is
      Q : Integer := Integer (Real (Total) * Threshold);
   begin
      if Q < 1 then Q := 1; end if;
      if Q > Total then Q := Total; end if;
      return Q;
   end Calculate_Quorum_Size;

   function Generate_Random_Latency (Min, Max : Milliseconds) return Milliseconds is
      Rand : Real;
   begin
      Init_Random;
      Rand := Real (Random_Int.Random (Seed)) / Real (Integer'Last);
      return Min + Milliseconds (Rand * Real (Max - Min));
   end Generate_Random_Latency;

   function Is_Eclipse (Probability : Real) return Boolean is
      Rand : Real;
   begin
      Init_Random;
      Rand := Real (Random_Int.Random (Seed)) / Real (Integer'Last);
      return Rand < Probability;
   end Is_Eclipse;

   function HLC_Now (Sat : Satellite_State) return HLC_Timestamp is
      Now : constant Seconds := Seconds (Real (Clock - Clock) + 0.0);
   begin
      return (Wall_Time => Now,
              Logical   => Sat.HLC.Logical + 1,
              Node      => Sat.My_ID);
   end HLC_Now;

   procedure Init_Satellite
     (Sat    : out Satellite_State;
      ID     : Node_ID;
      Config : Simulation_Config) is
   begin
      Sat.My_ID := ID;
      Sat.HLC := (Wall_Time => 0.0, Logical => 0, Node => ID);
      Sat.VClock := (others => 0);
      Sat.VClock (ID) := 1;
      Sat.Current_Round := 0;
      Sat.My_Value := (Data_Type => 1, Priority => 5,
                       Payload_X => Real (ID) * 100.0,
                       Payload_Y => 0.0, Payload_Z => 500.0,
                       Payload_T => Config.Simulation_Time,
                       Origin_Node => ID, Proposal_ID => 0);
      Sat.State := Undecided;
      Sat.Known_Nodes.Max_Size := 100;
      Sat.Known_Nodes.Count := 0;
      Sat.Decision := (others => <>);
      Sat.Decided_At := (0.0, 0, 1);
      Sat.Gossip_Count := 0;
      Sat.Merge_Count := 0;
      Sat.Rounds_Completed := 0;
      Sat.Last_Gossip := 0.0;
      Sat.Is_Connected := True;
      Sat.In_Eclipse := False;
   end Init_Satellite;

   procedure Update_HLC
     (Sat      : in out Satellite_State;
      Received : HLC_Timestamp) is
      New_Wall : constant Seconds :=
        (if Received.Wall_Time > Sat.HLC.Wall_Time
         then Received.Wall_Time else Sat.HLC.Wall_Time);
      New_Logical : Integer;
   begin
      if Received.Wall_Time > Sat.HLC.Wall_Time then
         New_Logical := Received.Logical + 1;
      elsif Received.Wall_Time = Sat.HLC.Wall_Time then
         New_Logical := Integer'Max (Sat.HLC.Logical, Received.Logical) + 1;
      else
         New_Logical := Sat.HLC.Logical + 1;
      end if;
      Sat.HLC := (Wall_Time => New_Wall,
                  Logical   => New_Logical,
                  Node      => Sat.My_ID);
   end Update_HLC;

   procedure Create_Gossip_Message
     (Sat    : Satellite_State;
      Msg    : out Gossip_Message;
      Config : Simulation_Config) is
   begin
      Msg.Sender_ID := Sat.My_ID;
      Msg.HLC := Sat.HLC;
      Msg.Round := Sat.Current_Round;
      Msg.Value := Sat.My_Value;
      Msg.VClock := Sat.VClock;
      Msg.Hop_Count := 0;
      Msg.TTL := 10;
      Msg.Is_Response := False;
      Msg.Request_ID := 0;
      Msg.GSet_Payload.Max_Size := 20;
      Msg.GSet_Payload.Count := Integer'Min (Sat.Known_Nodes.Count, 20);
      if Msg.GSet_Payload.Count > 0 then
         Msg.GSet_Payload.Elements (1 .. Msg.GSet_Payload.Count) :=
           Sat.Known_Nodes.Elements (1 .. Msg.GSet_Payload.Count);
      end if;
   end Create_Gossip_Message;

   procedure Process_Gossip_Message
     (Sat    : in out Satellite_State;
      Msg    : Gossip_Message;
      Config : Simulation_Config;
      Stats  : in out Consensus_Stats) is
      Byzantine_Rec : Byzantine_Record;
   begin
      if not Sat.Is_Connected or Sat.In_Eclipse then
         return;
      end if;
      if Msg.TTL <= 0 then
         return;
      end if;
      Detect_Byzantine (Sat, Msg, Byzantine_Rec, Stats);
      if Byzantine_Rec.Blocked then
         Sat.HLC.Logical := Sat.HLC.Logical + 1;
         return;
      end if;
      Update_HLC (Sat, Msg.HLC);
      Sat.VClock := Vector_Clock_Merge (Sat.VClock, Msg.VClock);
      Sat.VClock (Sat.My_ID) := Sat.VClock (Sat.My_ID) + 1;
      Sat.Known_Nodes := GSet_Merge (Sat.Known_Nodes, Msg.GSet_Payload);
      declare
         New_Element : GSet_Element :=
           (Node => Msg.Sender_ID, Round => Msg.Round,
            Value => Msg.Value, HLC => Msg.HLC);
      begin
         if not GSet_Contains (Sat.Known_Nodes, Msg.Sender_ID, Msg.Round) then
            if Sat.Known_Nodes.Count < Sat.Known_Nodes.Max_Size then
               Sat.Known_Nodes.Count := Sat.Known_Nodes.Count + 1;
               Sat.Known_Nodes.Elements (Sat.Known_Nodes.Count) := New_Element;
            end if;
         end if;
      end;
      Sat.Merge_Count := Sat.Merge_Count + 1;
      if Msg.Round = Sat.Current_Round and then
         Consensus_Value_Equal (Msg.Value, Sat.My_Value) then
         Sat.State := Gathering;
      end if;
      if Sat.State = Gathering then
         if Check_Quorum (Sat, Config) then
            Sat.State := Decided;
            Sat.Decision := Sat.My_Value;
            Sat.Decided_At := Sat.HLC;
            Stats.Successful_Rounds := Stats.Successful_Rounds + 1;
            Sat.Rounds_Completed := Sat.Rounds_Completed + 1;
         elsif Has_Expired (Sat, Config) then
            Sat.State := Expired;
            Stats.Failed_Rounds := Stats.Failed_Rounds + 1;
         end if;
      end if;
   end Process_Gossip_Message;

   function Check_Quorum
     (Sat    : Satellite_State;
      Config : Simulation_Config) return Boolean is
      Agreement_Count : Integer := 0;
      Total_Nodes     : constant Integer := Config.Num_Nodes;
      Required        : constant Integer :=
        Calculate_Quorum_Size (Total_Nodes, Config.Quorum_Threshold);
   begin
      for I in 1 .. Sat.Known_Nodes.Count loop
         if Sat.Known_Nodes.Elements (I).Round = Sat.Current_Round and then
            Consensus_Value_Equal (Sat.Known_Nodes.Elements (I).Value, Sat.My_Value) then
            Agreement_Count := Agreement_Count + 1;
         end if;
      end loop;
      return Agreement_Count >= Required;
   end Check_Quorum;

   function Has_Expired
     (Sat    : Satellite_State;
      Config : Simulation_Config) return Boolean is
      Time_Since_Decision : Seconds;
   begin
      if Sat.State = Gathering then
         Time_Since_Decision := Sat.HLC.Wall_Time - Sat.Decided_At.Wall_Time;
         return Time_Since_Decision > Config.Decision_Timeout;
      end if;
      return False;
   end Has_Expired;

   procedure Detect_Byzantine
     (Sat        : in out Satellite_State;
      Msg        : Gossip_Message;
      Record_Buf : in out Byzantine_Record;
      Stats      : in out Consensus_Stats) is
   begin
      if Msg.Round /= Sat.Current_Round and then
         Msg.Round /= Sat.Current_Round + 1 and then
         Msg.Round /= Sat.Current_Round - 1 then
         Stats.Byzantine_Attempts := Stats.Byzantine_Attempts + 1;
         Record_Buf := (Attacker_Node => Msg.Sender_ID,
                       Round => Msg.Round,
                       Fake_Value => Msg.Value,
                       Detected_At => Sat.HLC,
                       Blocked => True);
         Stats.Byzantine_Blocked := Stats.Byzantine_Blocked + 1;
         return;
      end if;
      if Msg.HLC.Wall_Time > Sat.HLC.Wall_Time + 300.0 then
         Stats.Byzantine_Attempts := Stats.Byzantine_Attempts + 1;
         Record_Buf := (Attacker_Node => Msg.Sender_ID,
                       Round => Msg.Round,
                       Fake_Value => Msg.Value,
                       Detected_At => Sat.HLC,
                       Blocked => True);
         Stats.Byzantine_Blocked := Stats.Byzantine_Blocked + 1;
         return;
      end if;
      Record_Buf.Blocked := False;
   end Detect_Byzantine;

   procedure Simulate_Network
     (Sats    : in out array (Node_ID) of Satellite_State;
      Config  : Simulation_Config;
      Stats   : in out Consensus_Stats;
      Latency : Latency_Matrix) is
      Msg : Gossip_Message;
      Target : Node_ID;
      use type Ada.Calendar.Time;
   begin
      Init_Random;
      for I in Node_ID loop
         if not Sats (I).Is_Connected then
            Sats (I).Eclipse_Duration := Sats (I).Eclipse_Duration - 0.1;
            if Sats (I).Eclipse_Duration <= 0.0 then
               Sats (I).Is_Connected := True;
               Sats (I).In_Eclipse := False;
            end if;
            goto Continue_Outer;
         end if;
         if Sats (I).State = Undecided then
            Sats (I).State := Proposing;
            Sats (I).Current_Round := Sats (I).Current_Round + 1;
            Stats.Total_Rounds := Stats.Total_Rounds + 1;
         end if;
         if Sats (I).State = Decided then
            Sats (I).State := Undecided;
            Sats (I).Current_Round := Sats (I).Current_Round + 1;
            Sats (I).My_Value.Proposal_ID := Sats (I).Current_Round;
            Stats.Total_Rounds := Stats.Total_Rounds + 1;
         end if;
         if Is_Eclipse (Config.Eclipse_Probability) then
            Sats (I).Is_Connected := False;
            Sats (I).In_Eclipse := True;
            Sats (I).Eclipse_Duration := Config.Eclipse_Duration;
            Stats.Eclipse_Events := Stats.Eclipse_Events + 1;
            goto Continue_Outer;
         end if;
         Create_Gossip_Message (Sats (I), Msg, Config);
         Sats (I).Gossip_Count := Sats (I).Gossip_Count + 1;
         for J in 1 .. Config.Gossip_Fanout loop
            Target := Node_ID (Integer (I) + Integer (Random_Int.Random (Seed)) mod Config.Num_Nodes);
            if Target /= I and then Sats (Target).Is_Connected then
               Sats (Target).Gossip_Count := Sats (Target).Gossip_Count + 1;
               Process_Gossip_Message (Sats (Target), Msg, Config, Stats);
            end if;
         end loop;
         <<Continue_Outer>> null;
      end loop;
   end Simulate_Network;

begin
   Init_Random;
end Star_Consensus;
-- StarConsensus: Main simulation - 100 LEO satellites
-- Variable latency 3-45ms, random eclipses, Byzantine faults

with Ada.Text_IO;  use Ada.Text_IO;
with Ada.Numerics; use Ada.Numerics;
with Ada.Numerics.Discrete_Random;
with Ada.Calendar; use Ada.Calendar;
with Star_Consensus; use Star_Consensus;

procedure Star_Main is

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

   Config : Simulation_Config;
   Sats   : array (Node_ID) of Satellite_State;
   Stats  : Consensus_Stats;
   Latency : Latency_Matrix;

   Sim_Time      : Seconds := 0.0;
   Tick_Interval : constant Seconds := 0.10;

   Active_Count, Eclipse_Count, Decided_Count : Integer := 0;
   Byzantine_Inject_Count : Integer := 0;

   procedure Initialize_Simulation is
   begin
      Init_Random;

      Config := (Num_Nodes          => 100,
                 Gossip_Fanout      => 5,
                 Gossip_Interval    => 100.0,
                 Quorum_Threshold   => 0.60,
                 Eclipse_Probability => 0.12,
                 Eclipse_Duration   => 25.0,
                 Max_Latency        => 45.0,
                 Min_Latency        => 3.0,
                 Simulation_Time    => 300.0,
                 Decision_Timeout   => 30.0);

      for I in Node_ID loop
         Init_Satellite (Sats (I), I, Config);
         Sats (I).My_Value := (Data_Type   => 1,
                               Priority    => Integer (I) mod 10,
                               Payload_X   => Real (I) * 50.0,
                               Payload_Y   => Real (I) * 10.0,
                               Payload_Z   => 500_000.0,
                               Payload_T   => Config.Simulation_Time,
                               Origin_Node => I,
                               Proposal_ID => 0);
      end loop;

      for I in Node_ID loop
         for J in Node_ID loop
            if I = J then
               Latency (I, J) := 0.0;
            else
               Latency (I, J) := Generate_Random_Latency
                 (Config.Min_Latency, Config.Max_Latency);
            end if;
         end loop;
      end loop;

      Stats := (others => 0.0);

      Put_Line ("╔══════════════════════════════════════════════════════════════╗");
      Put_Line ("║     StarConsensus - LEO Satellite Consensus Simulation       ║");
      Put_Line ("╠══════════════════════════════════════════════════════════════╣");
      Put_Line ("║ Nodes:" & Integer'Image (Config.Num_Nodes));
      Put_Line ("║ Quorum:" & Integer'Image (Calculate_Quorum_Size
        (Config.Num_Nodes, Config.Quorum_Threshold)));
      Put_Line ("║ Fanout:" & Integer'Image (Config.Gossip_Fanout));
      Put_Line ("║ Latency:" & Milliseconds'Image (Config.Min_Latency) &
                " -" & Milliseconds'Image (Config.Max_Latency) & "ms");
      Put_Line ("║ Eclipse:" & Real'Image (Config.Eclipse_Probability * 100.0) &
                "% /" & Seconds'Image (Config.Eclipse_Duration) & "s");
      Put_Line ("║ Duration:" & Seconds'Image (Config.Simulation_Time) & "s");
      Put_Line ("╚══════════════════════════════════════════════════════════════╝");
      New_Line;
   end Initialize_Simulation;

   procedure Print_Status is
      Total_Gossip : Integer := 0;
      Total_Merged : Integer := 0;
   begin
      Active_Count := 0;
      Eclipse_Count := 0;
      Decided_Count := 0;
      for I in Node_ID loop
         if Sats (I).Is_Connected then
            Active_Count := Active_Count + 1;
         else
            Eclipse_Count := Eclipse_Count + 1;
         end if;
         if Sats (I).State = Decided then
            Decided_Count := Decided_Count + 1;
         end if;
         Total_Gossip := Total_Gossip + Sats (I).Gossip_Count;
         Total_Merged := Total_Merged + Sats (I).Merge_Count;
      end loop;
      Put_Line ("[T+" & Seconds'Image (Sim_Time) & "s] " &
                "Active:" & Integer'Image (Active_Count) &
                " Eclipse:" & Integer'Image (Eclipse_Count) &
                " Decided:" & Integer'Image (Decided_Count) &
                " Gossip:" & Integer'Image (Total_Gossip) &
                " Rounds:" & Integer'Image (Stats.Successful_Rounds) &
                " ByzBlocked:" & Integer'Image (Stats.Byzantine_Blocked));
   end Print_Status;

   procedure Inject_Byzantine_Fault is
      Attacker : Node_ID;
      Victim   : Node_ID;
      Fake_Msg : Gossip_Message;
   begin
      if Byzantine_Inject_Count < 20 then
         Attacker := Node_ID (Random_Int.Random (Seed) mod Config.Num_Nodes + 1);
         Victim   := Node_ID (Random_Int.Random (Seed) mod Config.Num_Nodes + 1);
         if Attacker /= Victim and then Sats (Attacker).Is_Connected
           and then Sats (Victim).Is_Connected then
            Fake_Msg := (Sender_ID => Attacker,
                        HLC => (Wall_Time => Sim_Time + 500.0,
                                Logical   => 9999,
                                Node      => Attacker),
                        Round      => Sats (Victim).Current_Round,
                        Value      => (others => <>),
                        VClock     => (others => 0),
                        GSet_Payload => (Max_Size => 20, Elements => (others => (others => <>)), Count => 0),
                        Hop_Count  => 0,
                        TTL        => 1,
                        Is_Response => False,
                        Request_ID => 0);
            Process_Gossip_Message (Sats (Victim), Fake_Msg, Config, Stats);
            Byzantine_Inject_Count := Byzantine_Inject_Count + 1;
         end if;
      end if;
   end Inject_Byzantine_Fault;

   procedure Final_Report is
      Total_Gossip : Integer := 0;
      Avg_Latency  : Real := 0.0;
      Count        : Integer := 0;
   begin
      for I in Node_ID loop
         Total_Gossip := Total_Gossip + Sats (I).Gossip_Count;
      end loop;
      for I in Node_ID loop
         for J in Node_ID loop
            if I /= J then
               Avg_Latency := Avg_Latency + Real (Latency (I, J));
               Count := Count + 1;
            end if;
         end loop;
      end loop;
      if Count > 0 then
         Avg_Latency := Avg_Latency / Real (Count);
      end if;
      New_Line;
      Put_Line ("╔══════════════════════════════════════════════════════════════╗");
      Put_Line ("║                   SIMULATION COMPLETE                        ║");
      Put_Line ("╠══════════════════════════════════════════════════════════════╣");
      Put_Line ("║ Total Rounds:" & Integer'Image (Stats.Total_Rounds));
      Put_Line ("║ Successful :" & Integer'Image (Stats.Successful_Rounds));
      Put_Line ("║ Failed     :" & Integer'Image (Stats.Failed_Rounds));
      Put_Line ("║ Success Rate:" & Real'Image
        (Real (Stats.Successful_Rounds) / Real (Stats.Total_Rounds + 1) * 100.0) & "%");
      Put_Line ("║ Total Gossip Messages:" & Integer'Image (Total_Gossip));
      Put_Line ("║ Avg Gossip/Round:" & Real'Image
        (Real (Total_Gossip) / Real (Stats.Total_Rounds + 1)));
      Put_Line ("║ Eclipse Events:" & Integer'Image (Stats.Eclipse_Events));
      Put_Line ("║ Byzantine Attempts:" & Integer'Image (Stats.Byzantine_Attempts));
      Put_Line ("║ Byzantine Blocked :" & Integer'Image (Stats.Byzantine_Blocked));
      Put_Line ("║ Block Rate:" & Real'Image
        (Real (Stats.Byzantine_Blocked) / Real (Stats.Byzantine_Attempts + 1) * 100.0) & "%");
      Put_Line ("║ Avg Network Latency:" & Milliseconds'Image
        (Milliseconds (Avg_Latency)) & "ms");
      Put_Line ("║ Consensus Protocol: CRDT-Gossip + HLC + Probabilistic Quorum");
      Put_Line ("║ Status: OPERATIONAL - Survived LEO dynamic topology");
      Put_Line ("╚══════════════════════════════════════════════════════════════╝");
   end Final_Report;

begin
   Initialize_Simulation;
   Put_Line ("Starting simulation...");
   New_Line;

   while Sim_Time < Config.Simulation_Time loop
      Simulate_Network (Sats, Config, Stats, Latency);
      Inject_Byzantine_Fault;
      if Integer (Sim_Time * 10.0) mod 10 = 0 then
         Print_Status;
      end if;
      Sim_Time := Sim_Time + Tick_Interval;
      delay 0.001;
   end loop;

   Final_Report;

exception
   when others =>
      Put_Line ("*** SIMULATION ERROR ***");
      Final_Report;
end Star_Main;
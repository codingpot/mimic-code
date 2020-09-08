-- ------------------------------------------------------------------
-- Title: Sequential Organ Failure Assessment (SOFA)
-- This query extracts the sequential organ failure assessment (formally: sepsis-related organ failure assessment).
-- This score is a measure of organ failure for patients in the ICU.
-- The score is calculated on the first day of each ICU patients' stay.
-- ------------------------------------------------------------------

-- Reference for SOFA:
--    Jean-Louis Vincent, Rui Moreno, Jukka Takala, Sheila Willatts, Arnaldo De Mendonça,
--    Hajo Bruining, C. K. Reinhart, Peter M Suter, and L. G. Thijs.
--    "The SOFA (Sepsis-related Organ Failure Assessment) score to describe organ dysfunction/failure."
--    Intensive care medicine 22, no. 7 (1996): 707-710.

-- Variables used in SOFA:
--  GCS, MAP, FiO2, Ventilation status (sourced from CHARTEVENTS)
--  Creatinine, Bilirubin, FiO2, PaO2, Platelets (sourced from LABEVENTS)
--  Dobutamine, Epinephrine, Norepinephrine (sourced from INPUTEVENTS_MV and INPUTEVENTS_CV)
--  Urine output (sourced from OUTPUTEVENTS)

-- The following views required to run this query:
--  1) uofirstday - generated by urine-output-first-day.sql
--  2) vitalsfirstday - generated by vitals-first-day.sql
--  3) gcsfirstday - generated by gcs-first-day.sql
--  4) labsfirstday - generated by labs-first-day.sql
--  5) bloodgasfirstdayarterial - generated by blood-gas-first-day-arterial.sql
--  6) echodata - generated by echo-data.sql
--  7) ventdurations - generated by ventilation-durations.sql

-- Note:
--  The score is calculated for *all* ICU patients, with the assumption that the user will subselect appropriate STAY_IDs.
--  For example, the score is calculated for neonates, but it is likely inappropriate to actually use the score values for these patients.

with wt AS
(
  SELECT ie.stay_id
    -- ensure weight is measured in kg
    , avg(CASE
        WHEN itemid IN (762, 763, 3723, 3580, 226512)
          THEN valuenum
        -- convert lbs to kgs
        WHEN itemid IN (3581)
          THEN valuenum * 0.45359237
        WHEN itemid IN (3582)
          THEN valuenum * 0.0283495231
        ELSE null
      END) AS weight

  from `physionet-data.mimic_icu.icustays` ie
  left join `physionet-data.mimic_icu.chartevents` c
    on ie.stay_id = c.stay_id
  WHERE valuenum IS NOT NULL
  AND itemid IN
  (
    762, 763, 3723, 3580,                     -- Weight Kg
    3581,                                     -- Weight lb
    3582,                                     -- Weight oz
    226512 -- Metavision: Admission Weight (Kg)
  )
  AND valuenum != 0
  and charttime between DATETIME_SUB(ie.intime, interval 1 day) and DATETIME_ADD(ie.intime, interval 1 day)
  -- exclude rows marked as error
  AND c.warning != 1
  group by ie.stay_id
)
, vaso_mv as
(
  select ie.stay_id
    -- case statement determining whether the ITEMID is an instance of vasopressor usage
    , max(case when itemid = 221906 then rate end) as rate_norepinephrine
    , max(case when itemid = 221289 then rate end) as rate_epinephrine
    , max(case when itemid = 221662 then rate end) as rate_dopamine
    , max(case when itemid = 221653 then rate end) as rate_dobutamine
  from `physionet-data.mimic_icu.icustays` ie
  inner join `physionet-data.mimic_icu.inputevents` mv
    on ie.stay_id = mv.stay_id and mv.starttime between ie.intime and DATETIME_ADD(ie.intime, interval 1 day)
  where itemid in (221906,221289,221662,221653)
  -- 'Rewritten' orders are not delivered to the patient
  and statusdescription != 'Rewritten'
  group by ie.stay_id
)
, pafi1 as
(
  -- join blood gas to ventilation durations to determine if patient was vent
  select bg.stay_id, bg.charttime
  , PaO2FiO2
  , case when vd.stay_id is not null then 1 else 0 end as IsVent
  from `physionet-data.mimic_icu.bloodgasfirstdayarterial` bg
  left join `physionet-data.mimic_icu.ventdurations` vd
    on bg.stay_id = vd.stay_id
    and bg.charttime >= vd.starttime
    and bg.charttime <= vd.endtime
  order by bg.stay_id, bg.charttime
)
, pafi2 as
(
  -- because pafi has an interaction between vent/PaO2:FiO2, we need two columns for the score
  -- it can happen that the lowest unventilated PaO2/FiO2 is 68, but the lowest ventilated PaO2/FiO2 is 120
  -- in this case, the SOFA score is 3, *not* 4.
  select stay_id
  , min(case when IsVent = 0 then PaO2FiO2 else null end) as PaO2FiO2_novent_min
  , min(case when IsVent = 1 then PaO2FiO2 else null end) as PaO2FiO2_vent_min
  from pafi1
  group by stay_id
)
-- Aggregate the components for the score
, scorecomp as
(
select ie.stay_id
  , v.MeanBP_Min
  , mv.rate_norepinephrine as rate_norepinephrine
  , mv.rate_epinephrine as rate_epinephrine
  , mv.rate_dopamine as rate_dopamine
  , mv.rate_dobutamine as rate_dobutamine

  , l.Creatinine_Max
  , l.Bilirubin_Max
  , l.Platelet_Min

  , pf.PaO2FiO2_novent_min
  , pf.PaO2FiO2_vent_min

  , uo.UrineOutput

  , gcs.MinGCS
from `physionet-data.mimic_icu.icustays` ie
left join vaso_mv mv
  on ie.stay_id = mv.stay_id
left join pafi2 pf
 on ie.stay_id = pf.stay_id
left join `physionet-data.mimic_icu.vitalsfirstday` v
  on ie.stay_id = v.stay_id
left join `physionet-data.mimic_icu.labsfirstday` l
  on ie.stay_id = l.stay_id
left join `physionet-data.mimic_icu.uofirstday` uo
  on ie.stay_id = uo.stay_id
left join `physionet-data.mimic_icu.gcsfirstday` gcs
  on ie.stay_id = gcs.stay_id
)
, scorecalc as
(
  -- Calculate the final score
  -- note that if the underlying data is missing, the component is null
  -- eventually these are treated as 0 (normal), but knowing when data is missing is useful for debugging
  select stay_id
  -- Respiration
  , case
      when PaO2FiO2_vent_min   < 100 then 4
      when PaO2FiO2_vent_min   < 200 then 3
      when PaO2FiO2_novent_min < 300 then 2
      when PaO2FiO2_novent_min < 400 then 1
      when coalesce(PaO2FiO2_vent_min, PaO2FiO2_novent_min) is null then null
      else 0
    end as respiration

  -- Coagulation
  , case
      when platelet_min < 20  then 4
      when platelet_min < 50  then 3
      when platelet_min < 100 then 2
      when platelet_min < 150 then 1
      when platelet_min is null then null
      else 0
    end as coagulation

  -- Liver
  , case
      -- Bilirubin checks in mg/dL
        when Bilirubin_Max >= 12.0 then 4
        when Bilirubin_Max >= 6.0  then 3
        when Bilirubin_Max >= 2.0  then 2
        when Bilirubin_Max >= 1.2  then 1
        when Bilirubin_Max is null then null
        else 0
      end as liver

  -- Cardiovascular
  , case
      when rate_dopamine > 15 or rate_epinephrine >  0.1 or rate_norepinephrine >  0.1 then 4
      when rate_dopamine >  5 or rate_epinephrine <= 0.1 or rate_norepinephrine <= 0.1 then 3
      when rate_dopamine >  0 or rate_dobutamine > 0 then 2
      when MeanBP_Min < 70 then 1
      when coalesce(MeanBP_Min, rate_dopamine, rate_dobutamine, rate_epinephrine, rate_norepinephrine) is null then null
      else 0
    end as cardiovascular

  -- Neurological failure (GCS)
  , case
      when (MinGCS >= 13 and MinGCS <= 14) then 1
      when (MinGCS >= 10 and MinGCS <= 12) then 2
      when (MinGCS >=  6 and MinGCS <=  9) then 3
      when  MinGCS <   6 then 4
      when  MinGCS is null then null
  else 0 end
    as cns

  -- Renal failure - high creatinine or low urine output
  , case
    when (Creatinine_Max >= 5.0) then 4
    when  UrineOutput < 200 then 4
    when (Creatinine_Max >= 3.5 and Creatinine_Max < 5.0) then 3
    when  UrineOutput < 500 then 3
    when (Creatinine_Max >= 2.0 and Creatinine_Max < 3.5) then 2
    when (Creatinine_Max >= 1.2 and Creatinine_Max < 2.0) then 1
    when coalesce(UrineOutput, Creatinine_Max) is null then null
  else 0 end
    as renal
  from scorecomp
)
select ie.subject_id, ie.hadm_id, ie.stay_id
  -- Combine all the scores to get SOFA
  -- Impute 0 if the score is missing
  , coalesce(respiration,0)
  + coalesce(coagulation,0)
  + coalesce(liver,0)
  + coalesce(cardiovascular,0)
  + coalesce(cns,0)
  + coalesce(renal,0)
  as SOFA
, respiration
, coagulation
, liver
, cardiovascular
, cns
, renal
from `physionet-data.mimic_icu.icustays` ie
left join scorecalc s
  on ie.stay_id = s.stay_id
;
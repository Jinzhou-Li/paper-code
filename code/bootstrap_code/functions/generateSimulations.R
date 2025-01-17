###########################################################
## generateSimulations.R
## author: J.S. Huisman
###########################################################
# 
# source('2_utils_getInfectionIncidence.R')
# source('3_utils_doReEstimates.R')

library(fitdistrplus)
library(tidyverse)
library(EpiEstim)

# The most important function is simulateTS - used to simulate
# infections and observations from a given Re trajectory/scenario

# To estimate infections from observations (using deconvolution)
# and Re from infections; we use the functions from our general method
# these are read in from the scripts '2_...' and '3_...' above;
# and require the wrappers estimateInfectionTS and estimateReTS
# to work with the simulated data



###########################################################
###### Generate Re TS ######
# input: timepoints, plateau R values
# output: Re timeseries (piecewise constant)
getReTS <- function(shift_times, R_levels){
  t_norm = shift_times - shift_times[1]
  n_t = length(t_norm)
  
  ReTS <- vector(mode = 'numeric', length = t_norm[n_t])
  R_count = 1
  for (t_i in 1:(n_t-1)){
    if (t_i %% 2 != 0){
      # odd
      ReTS[(t_norm[t_i]+1):t_norm[t_i+1]] <- R_levels[R_count]
      R_count = R_count + 1
    } else{
      # even
      ReTS[t_norm[t_i]:(t_norm[t_i+1]+1)] <- seq(from = R_levels[R_count-1], to = R_levels[R_count], 
                                           length.out = (t_norm[t_i+1]-t_norm[t_i]+2)) 
    }
  }
  
  return(ReTS)
}
# Example use 
# shift_times = c(0, 30, 40, 50, 60, 80)
# R_levels = c(4, 0.5, 1.2)
# ReTS <- getReTS(shift_times, R_levels)
# ReTS_smooth <- getSmoothReTS(shift_times, R_levels, days_incl = 14)
# plot(ReTS)
# plot(ReTS_smooth)

# use LOESS smoothing on the piecewise constant Re trajectory
getSmoothReTS <- function(shift_times, R_levels, days_incl = 14) {
  
  ReTS <- getReTS(shift_times, R_levels)

  n_points <- length(ReTS)
  sel_span <- days_incl / n_points
  
  df <- data.frame(date = 1:n_points, R = ReTS)
  c_data.lo <- loess(R ~ date, data = df, span = sel_span, degree = 1)
  
  smoothed_R <- predict(c_data.lo)

  return(smoothed_R)
}


###### Generate Infection TS ######

getDiscreteSIperDay <- function(k, shapeG=2.73, scaleG=1.39) {
  ### Expression from Cori et al. 2013, Web appendix 11
  #serial interval SI is such that SI -1 is Gamma distributed
  wk <- k * pgamma(k, shape=shapeG, scale=scaleG) +
    (k-2) * pgamma(k-2, shape=shapeG, scale=scaleG) +
    (-2) * (k-1) * pgamma(k-1, shape=shapeG, scale=scaleG) +
    shapeG * scaleG * (2 * pgamma(k-1, shape=shapeG+1, scale=scaleG) - 
                           pgamma(k-2, shape=shapeG+1, scale=scaleG) - 
                           pgamma(k, shape=shapeG+1, scale=scaleG)) 
  return(wk)
}

getDiscreteSerialInterval <- function(shapeG=2.73, scaleG=1.39){
  longDSI <- sapply(0:1000, getDiscreteSIperDay, shapeG, scaleG)
  cutDSI <- min(which(longDSI[2:1000]==0))
  DiscreteSerialInterval <- longDSI[1:cutDSI]
  
  return(DiscreteSerialInterval)
}

getInfectionsDayT <- function(RT, InfectionsBeforeT, DiscreteSerialInterval){
  # Assumption: DSI starts from 0; here we use from day 1
  memory = min(length(InfectionsBeforeT), length(DiscreteSerialInterval)-1)
  LambdaDayT = RT * sum(rev(InfectionsBeforeT)[1:memory]*
                              DiscreteSerialInterval[2:(memory+1)])
  
  InfectionsDayT = rpois(1, LambdaDayT)
  
  return(round(InfectionsDayT))
}

# input:
# - timeseries of Re
# - serial interval distribution
# output:
# - timeseries of infections
getInfectionTS <- function(ReTS, init_infection = 1, ...){
  # can supply shapeG and scaleG to pass to DSI function
  n_ts = length(ReTS)
  n_init = length(init_infection)
  DiscreteSerialInterval = getDiscreteSerialInterval(...)
  
  infectionTS = vector(mode="numeric", length = n_ts + n_init - 1)
  infectionTS[1:n_init] = init_infection
  
  for(i in 2:n_ts){
    infectionTS[n_init-1+i] = getInfectionsDayT(ReTS[i], 
                                       infectionTS[1:(n_init+i-2)], 
                                       DiscreteSerialInterval)
  }
  
  infectionTS = infectionTS[n_init:(n_init+n_ts-1)]
  return(infectionTS)
}

# Example use
# infectionTS <- getInfectionTS(ReTS)
# plot(infectionTS)

###### Generate Observation TS ######

# find gamma parameters from mean/sd of distribution
getGammaParams <- function(meanParam, sdParam){
  shapeParam <- meanParam^2 / (sdParam^2)
  scaleParam <- (sdParam^2) / meanParam
  return(list(shape = shapeParam, scale = scaleParam))
}

# find mean/sd of distribution from gamma parameters
getInvGammaParams <- function(shapeParam, scaleParam){
  meanParam <- scaleParam * shapeParam
  sdParam <- sqrt(scaleParam^2 * shapeParam)
  return(list(mean = meanParam, sd = sdParam))
}

# draw observations from double gamma distribution
drawDoubleGamma <- function(n_draws, IncubationParams, OnsetToCountParams){
  draws <- round(rgamma(n_draws, shape = OnsetToCountParams$shape,
           scale = OnsetToCountParams$scale) +
     rgamma(n_draws, shape = IncubationParams$shape,
             scale = IncubationParams$scale))
  return(draws)
}

addTSnoise <- function(observationTS, noise){
  origObsTS <- observationTS
  allObservationDates = 1:length(origObsTS)
  
  if ('weekly' %in% names(noise)){
    # we just care about the 7-day pattern, not which day exactly is a weekend
    
    saturdays = which((allObservationDates %% 7) == 0)
    sat_reduct <- rnorm(length(saturdays), noise$weekly, noise$weekly/10)
    sat_reduct[sat_reduct>1] = 1
    sat_reduct[sat_reduct<0] = 0
    
    observationTS[saturdays] = sat_reduct * origObsTS[saturdays]
    observationTS[saturdays+2] = origObsTS[saturdays+2] + (1 - sat_reduct) * origObsTS[saturdays]
    
    sundays = which((allObservationDates %% 7) == 1)
    sun_reduct <- rnorm(length(sundays), noise$weekly, noise$weekly/10)
    sun_reduct[sun_reduct>1] = 1
    sun_reduct[sun_reduct<0] = 0
    
    observationTS[sundays] = sun_reduct * origObsTS[sundays]
    observationTS[sundays+2] = origObsTS[sundays+2] + (1 - sun_reduct) * origObsTS[sundays]
  }
  
  if ('gaussian' %in% names(noise)){
    mult_noise <- rnorm(length(observationTS), mean = 1, sd = noise$gaussian)
    observationTS = mult_noise * observationTS
  }
  
  if ('fitted_noise_model' %in% names(noise)){
    mult_noise <- simulate(noise$fitted_noise_model)     # noise model is on log-scale
    
    if(length(mult_noise) != length(observationTS)) {print("length(mult_noise) != observationTS in the fitted time series model!!!")}
    
    # y  =  mu * residual
    observationTS = observationTS * exp(mult_noise)
  }
  
  if ('iid_noise_sd' %in% names(noise)){
    mult_noise <- rnorm(length(observationTS), mean = 0, sd = noise$iid_noise_sd)
    
    # y  =  mu * residual
    observationTS = observationTS * exp(mult_noise)     # so the error is iid log-normal
  }
  
  if ('noiseless' %in% names(noise)){   # used for SemiPara Boot
    observationTS = observationTS
  }
  
  observationTS = round(observationTS)
  observationTS[observationTS < 0] = 0
  
  return(observationTS)
}

timevaryingDelayDist <- function(onset_date, OnsetToCountParams){
  
  invParams = getInvGammaParams(shapeParam = OnsetToCountParams$shape, 
                                scaleParam = OnsetToCountParams$scale)
  
  # 1/20 less per day; no lower than 2 days
  newMean = max(invParams$mean - onset_date/20.0, 2.0)
  
  NewOnsetToCountParams <- getGammaParams(newMean, invParams$sd)
  
  return(NewOnsetToCountParams)
}


getEmpCountDelayDist <- function(infectionTS, IncubationParams, OnsetToCountParams,
                                 subsample = 0.4){
  n_ts = length(infectionTS)
  
  delay_df <- data.frame()
  for (infection_date in 1:n_ts) {
    
    # not sure this is the right distribution to use
    # just want to make sure it is occasionally above 0.5 such that
    # days with incidence of 1 stand a chance of being sampled
    subsample_frac = min(abs(rnorm(1, mean = subsample, sd = 1)), 1)
    
    if (round(infectionTS[infection_date]*subsample_frac) > 0){
      sampledOnsets <- round(rgamma(infectionTS[infection_date], 
                                    shape = IncubationParams$shape, 
                                    scale = IncubationParams$scale))
      
      drawnOnsetDates <- infection_date + sampledOnsets
      
      sampledDelays <-  sapply(drawnOnsetDates, function(onset_date){
        delay_dist = timevaryingDelayDist(onset_date, OnsetToCountParams)
        return( round(rgamma(1, 
                             shape = delay_dist$shape, 
                             scale = delay_dist$scale)) )
      })
      
      drawnCountDates <- drawnOnsetDates + sampledDelays
      
      
      new_delay_df <- data.frame(data_type = 'Simulated',
                                 onset_date = Sys.Date() + drawnOnsetDates,
                                 count_date = Sys.Date() + drawnCountDates,
                                 delay = sampledDelays,
                                 source = 'ETH',
                                 region = 'Simulated',
                                 country = 'Simulated')
      
      delay_df = bind_rows(delay_df, new_delay_df)
    }
  }
  return(delay_df)
}

# input
# - timeseries of infections
# - delay distribution
# output
# - time series of observations
getObservationTS <- function(infectionTS, IncubationParams, OnsetToCountParams,
                             noise = list('weekly' = 0.3, 'gaussian' = 0.1),
                             timevarying = FALSE, truncate = 'empirical'){
  
  n_ts = length(infectionTS)

  n_infect_tot <- sum(infectionTS)
  ObservationDates <- c()
  #infection_date = 1
  for (infection_date in 1:n_ts) {
     
    if (infectionTS[infection_date] > 0){
      if (timevarying){
        sampledOnsets <- round(rgamma(infectionTS[infection_date], 
                                      shape = IncubationParams$shape, 
                                      scale = IncubationParams$scale))
        
        drawnOnsetDates <- infection_date + sampledOnsets
          
        sampledDelays <-  sapply(drawnOnsetDates, function(onset_date){
          delay_dist = timevaryingDelayDist(onset_date, OnsetToCountParams)
          return( round(rgamma(1, 
                       shape = delay_dist$shape, 
                       scale = delay_dist$scale)) )
          })
        
        drawnCountDates <- drawnOnsetDates + sampledDelays
        
      } else {
        sampledDelays <- drawDoubleGamma(infectionTS[infection_date],
                                         IncubationParams,
                                         OnsetToCountParams)
        
        drawnCountDates <- infection_date + sampledDelays
      }
      ObservationDates <- c(ObservationDates, drawnCountDates)
    }
  }
  
  allObservationDates <- seq(1, max(ObservationDates, n_ts))
  
  # -1 because we add all dates
  observationTS <- unname( table( c(ObservationDates, allObservationDates) ) ) -1
  observationTS <- as.numeric(observationTS)

  # origObsTS <- observationTS
  
  observationTS_cut <- observationTS[1:length(infectionTS)]
  observationTS <- addTSnoise(observationTS_cut, noise)
  
  # Cut-off the timeseries a bit earlier than the last observation
  # if (truncate == 'empirical'){
  #   delay_sample <- drawDoubleGamma(10000,
  #                                   IncubationParams,
  #                                   OnsetToCountParams)
  #   extension = min(n_ts + median(delay_sample), length(origObsTS))
  #   observationTS = observationTS[1:extension]
  # }

  return(observationTS)
}


# IncubationParams <- getGammaParams(meanParam = 5.3, sdParam = 3.2)
# # onset to death: mean =15.0 sd=6.9 (Linton et al. best gamma distr fit)
# OnsetToCountParams = getGammaParams(15.0, 6.9)
# 
# ObservationTS <- getObservationTS(infectionTS,
#                                   IncubationParams, OnsetToCountParams)
# 
# plot(ObservationTS)

###########################################################
###### Simulation Master Script ######
simulateTS <- function(shift_times, R_levels,
                       IncubationParams, OnsetToCountParams, noise = list(),
                       timevarying = FALSE, smooth_R = FALSE,
                       ...){
  # With the dots one can specify shapeG, scaleG
  
  if (smooth_R){
    ReTS <- getSmoothReTS(shift_times, R_levels)
  } else{
    ReTS <- getReTS(shift_times, R_levels)
  }
  
  infectionTS <- getInfectionTS(ReTS, ...)
  ObservationTS <- getObservationTS(infectionTS, 
                                    IncubationParams, OnsetToCountParams, noise = noise,
                                    timevarying = timevarying)
  
  ## the observation timeseries will be longer by a few days; we cut this off
  n_re <- length(ReTS)
  #n_obs <- length(ObservationTS)
  result <- data.frame(list(Re = ReTS, 
                            infections = infectionTS, 
                            observations = ObservationTS[1:n_re],
                            date = as_date("2020-02-01") + 1:n_re) )
  return(result)
}

###### Validate Deconvolution ######

getSimIncidence <- function(simulation){
  
  observation_df <- simulation %>%
    dplyr::select(date, value = observations) %>%
    mutate(data_type = 'Simulated',
           source = 'ETH',
           variable = 'incidence',
           region = 'Simulated',
           country = 'Simulated',
           date_type = 'report',
           local_infection = TRUE)
  
  return(observation_df)
}

# test deconvolution against "real" infection curve
estimateInfectionTS <- function(simulation, IncubationParams, OnsetToCountParams,
                                smooth_param = FALSE, 
                                smooth_para_deConv,
                                timevarying = FALSE, n_boot = 50){
  infection_df <- getSimIncidence(simulation)
  
  constant_delay_distributions <- list("Simulated" = get_vector_constant_waiting_time_distr(
    IncubationParams$shape, IncubationParams$scale,
    OnsetToCountParams$shape, OnsetToCountParams$scale),
    "Symptoms" = get_vector_constant_waiting_time_distr(
      IncubationParams$shape, IncubationParams$scale,
      0, 0))
  
  # load empirical delays
  if (timevarying){
    delays_onset_to_count <- getEmpCountDelayDist(infection_df$value, IncubationParams, OnsetToCountParams)
  } else {
    delays_onset_to_count <- tibble()  
  }
  
  estimatedInfections <- get_infection_incidence_by_deconvolution(
      infection_df,
      is_local_cases = T,
      constant_delay_distribution = constant_delay_distributions[['Simulated']],
      constant_delay_distribution_incubation = constant_delay_distributions[["Symptoms"]],
      max_iterations = 100,
      smooth_incidence = smooth_param,
      smooth_para_deConv = smooth_para_deConv,
      empirical_delays = delays_onset_to_count,
      n_bootstrap = n_boot,
      verbose = FALSE)
  
  return(estimatedInfections)
}

# estimatedInfections <- estimateInfectionTS(simulation, IncubationParams, OnsetToCountParams)

###### Validate Re Estimation ######

# test Re estimates against "real" Re estimates

estimateReTS <- function(estimatedInfections, delay = 0){
  all_delays <- list("infection_Simulated" = c(Cori = delay))
  
  truncations <- list(left = c(Cori = 5), right = c(Cori = 0))
  
  
  rawEstimatedRe <- doAllReEstimations(
    estimatedInfections,
    slidingWindow = 3,
    #slidingWindow = 1,
    methods = "Cori",
    variationTypes = c("slidingWindow"),
    all_delays = all_delays,
    truncations = truncations,
    interval_ends = max(estimatedInfections$date),
    additional_interval_ends = data.frame(region = "Simulated",
                                          data_type = "Simulated",
                                          date = max(estimatedInfections$date)))
  
  estimatedRe <- as_tibble(rawEstimatedRe)

  return(estimatedRe)
}

cleanReTSestimate <- function(rawEstimatedRe){
  estimatedRe <- as_tibble(rawEstimatedRe) %>%
    pivot_wider(names_from = "variable", values_from = "value") %>%
    group_by(date, country, region, data_type, source, estimate_type) %>%
    summarize(
      median_R_mean = median(R_mean),
      median_R_highHPD = median(R_highHPD),
      median_R_lowHPD = median(R_lowHPD),
      median_R_sample = median(R_sample),
      .groups = "keep"
    ) %>%
    dplyr::select(country, region, source, data_type, estimate_type, date,
           median_R_mean, median_R_highHPD, median_R_lowHPD, median_R_sample) %>%
    arrange(country, region, source, data_type, estimate_type, date) %>%
    ungroup()
  return(estimatedRe)
}

#estimatedRe <- estimateReTS(estimatedInfections, delay = 0)

### Apply EpiEstim R estimation method to 'incidenceData' timeseries with 'dates' the dates associated
##
## 'estimateOffsetting' is the number of days the estimates are to be shifted towards the past
##    (to account for delay between infection and testing/hospitalization/death..)
## 'ledtTruncation' is the number of days of estimates that should be ignored at the start of the time series
## 'method' takes value either 'Cori' or  'WallingaTeunis'. 'Cori' is the classic EpiEstim R(t) method, 'WallingaTeunis'
##    is the method by Wallinga and Teunis (also implemented in EpiEstim)
## 'minimumCumul' is the minimum cumulative count the incidence data needs to reach before the first Re estimate is
##    attempted (if too low, EpiEstim can crash)
## 'windowLength' is the size of the sliding window used in EpiEstim
## 'mean_si' and 'std_si' are the mean and SD of the serial interval distribution used by EpiEstim
estimateRe <- function(
  dates,
  incidenceData,
  estimateOffsetting = 10,
  rightTruncation = 0,
  leftTruncation = 5,
  method = "Cori",
  variationType = "slidingWindow",
  interval_ends = c("2020-03-13", "2020-03-16", "2020-03-20"),
  minimumCumul = 5,
  windowLength= 4,
  mean_si = 4.8,
  std_si  = 2.3) {

  offset <- 1
  cumulativeIncidence <- 0
  while (cumulativeIncidence < minimumCumul) {
    if (offset > nrow(incidenceData)) {
      return(data.frame(date = c(), variable = c(), value = c(), estimate_type = c()))
    }
    cumulativeIncidence <- cumulativeIncidence + incidenceData[offset, 1]
    offset <- offset + 1
  }
  
  ## offset needs to be at least two for EpiEstim
  offset <- max(2, offset)

  rightBound <- nrow(incidenceData) - (windowLength - 1)

  if (rightBound < offset) { ## no valid data point, return empty estimate
    return(data.frame(date = c(), variable = c(), value = c(), estimate_type = c()))
  }

  ## generate start and end bounds for Re estimates
  if (variationType == "step") {

    # index in incidenceData that corresponds to the interval_end date
    interval_end_indices <- sapply(
      interval_ends,
      function(x) {
        which(dates == as.Date(x))[1]
      }
    )

    #starts and end indices of the intervals (numeric vector)
    # t_start = interval_end + 1
    t_start <- c(offset, na.omit(interval_end_indices) + 1)
    t_end <- c(na.omit(interval_end_indices), nrow(incidenceData))

    if (offset >= nrow(incidenceData)) {
      return(data.frame(date = c(), variable = c(), value = c(), estimate_type = c()))
    }

    # remove intervals if the offset is greater than the
    # end of the interval
    while (offset > t_end[1]) {
      t_start <- t_start[-1]
      t_start[1] <- offset
      t_end <- t_end[-1]
    }

    # make sure there are no intervals beyond the length of the data
    while (t_start[length(t_start)] >= nrow(incidenceData)) {
      t_end <- t_end[-length(t_end)]
      t_start <- t_start[-length(t_start)]
    }

    outputDates <- dates[t_start[1]:t_end[length(t_end)]]

  } else if (variationType == "slidingWindow") {
    # computation intervals corresponding to every position of the
    # sliding window
    t_start <- seq(offset, rightBound)
    t_end <- t_start + windowLength - 1
    outputDates <- dates[t_end]
  } else {
    print("Unknown time variation.")
    return(data.frame(date = c(), variable = c(), value = c(), estimate_type = c()))
  }

  ## offset dates to account for delay between infection and recorded event (testing, hospitalization, death...)
  outputDates <- outputDates - estimateOffsetting

  if (method == "Cori") {
    R_instantaneous <- estimate_R(
      incidenceData,
      method = "parametric_si",
      config = make_config(
        list(
          mean_si = mean_si,
          std_si = std_si,
          t_start = t_start,
          t_end = t_end,
          mean_prior = 1)
      )
    )
  } else if (method == "WallingaTeunis") {
    R_instantaneous <- wallinga_teunis(
      incidenceData,
      method = "parametric_si",
      config = list(
        mean_si = mean_si, std_si = std_si,
        t_start = t_start,
        t_end = t_end,
        n_sim = 10)
    )
  } else {
    print("Unknown estimation method")
    return(data.frame(date = c(), variable = c(), value = c(), estimate_type = c()))
  }

  if (variationType == "step") {
    R_mean <- unlist(lapply(seq_along(t_start),
                            function(x) {
                              rep(R_instantaneous$R$`Mean(R)`[x], t_end[x] - t_start[x] + 1)
                            }
    ))
    R_highHPD <- unlist(lapply(seq_along(t_start),
                               function(x) {
                                 rep(R_instantaneous$R$`Quantile.0.975(R)`[x], t_end[x] - t_start[x] + 1)
                               }
    ))
    R_lowHPD <- unlist(lapply(seq_along(t_start),
                              function(x) {
                                rep(R_instantaneous$R$`Quantile.0.025(R)`[x], t_end[x] - t_start[x] + 1)
                              }
    ))
  } else {
    
    R_mean <- R_instantaneous$R$`Mean(R)`
    R_highHPD <- R_instantaneous$R$`Quantile.0.975(R)`
    R_lowHPD <- R_instantaneous$R$`Quantile.0.025(R)`
    
    ### sample R from posterior. 
    #R_sample <- sample_posterior_R(R_instantaneous, n=length(R_mean), window = 1:length(R_mean))
    
    # save(R_instantaneous, file = "SimulatedSetting/R_instantaneous.RData")
    
  }

  if (rightTruncation > 0) {
    if (rightTruncation >= length(outputDates)) {
      return(data.frame(date = c(), variable = c(), value = c(), estimate_type = c()))
    }
    originalLength <- length(outputDates)
    outputDates <- outputDates[-seq(originalLength, by = -1, length.out = rightTruncation)]
    
    R_mean <- R_mean[-seq(originalLength, by = -1, length.out = rightTruncation)]
    R_highHPD <- R_highHPD[-seq(originalLength, by = -1, length.out = rightTruncation)]
    R_lowHPD <- R_lowHPD[-seq(originalLength, by = -1, length.out = rightTruncation)]
    
    # Ask: ok to put it here?
    # R_sample <- R_sample[-seq(originalLength, by = -1, length.out = rightTruncation)]
  }

  if (leftTruncation > 0) {
    if (leftTruncation >= length(outputDates)) {
      return(data.frame(date = c(), variable = c(), value = c(), estimate_type = c()))
    }
    originalLength <- length(outputDates)
    outputDates <- outputDates[-seq(1, leftTruncation)]
    
    R_mean <- R_mean[-seq(1, leftTruncation)]
    R_highHPD <- R_highHPD[-seq(1, leftTruncation)]
    R_lowHPD <- R_lowHPD[-seq(1, leftTruncation)]
    
    # Ask: ok to put it here?
    #R_sample <- R_sample[-seq(1, leftTruncation)]
  }

  result <- data.frame(
    date = outputDates,
    R_mean = R_mean,
    R_highHPD = R_highHPD,
    R_lowHPD = R_lowHPD)
    #R_sample = R_sample)

  result <- reshape2::melt(result, id.vars = "date")
  colnames(result) <- c("date", "variable", "value")
  result$estimate_type <- paste0(method, "_", variationType)

  return(result)
}

doReEstimation <- function(
  data_subset,
  slidingWindow = 1,
  methods,
  variationTypes,
  interval_ends = c("2020-04-01"),
  delays,
  truncations) {

  end_result <-  data.frame()

  for (method_i in methods) {
    for (variation_i in variationTypes) {
      
      if(nrow(data_subset %>% filter(local_infection == F)) > 0) {
        incidence_data_local <- data_subset %>% filter(local_infection == T) %>% pull(value)
        incidence_data_import <- data_subset %>% filter(local_infection == F) %>% pull(value)
        
        incidence_data <- data.frame(local = incidence_data_local,
                            imported = incidence_data_import)
      } else {
        incidence_data <- data.frame(I = data_subset %>% filter(local_infection == T) %>% pull(value))
      }
      
      dates <- data_subset %>% filter(local_infection == T) %>% pull(date)

      offsetting <- delays[method_i]

      leftTrunc <- truncations$left[method_i]
      rightTrunc <- truncations$right[method_i]

      result <- estimateRe(
        dates = dates,
        incidenceData = incidence_data,
        windowLength =  slidingWindow,
        estimateOffsetting = offsetting,
        rightTruncation = rightTrunc,
        leftTruncation = leftTrunc,
        method = method_i,
        variationType = variation_i,
        interval_ends = interval_ends)
      if (nrow(result) > 0) {
        result$region <- unique(data_subset$region)[1]
        result$country <- unique(data_subset$country)[1]
        result$source <- unique(data_subset$source)[1]
        result$data_type <- unique(data_subset$data_type)[1]
        result$replicate <- unique(data_subset$replicate)[1]
        ## need to reorder columns in 'results' dataframe to do the same as in data
        result <- result[, c(
          "date", "region", "country", "source", "data_type", "estimate_type",
          "replicate", "value", "variable")]
        end_result <- bind_rows(end_result, result)
      }
    }
  }

  return(end_result)
}

## Intervention Dates for the European countries
getIntervalEnds <- function(
  interval_ends,
  region_i,
  swissRegions = c("LIE", "AG", "AI", "AR", "BE", "BL", "BS", "FR", "GE", "GL",
                   "GR", "grR Central Switzerland", "grR Eastern Switzerland",
                   "grR Espace Mittelland", "grR Lake Geneva Region", "grR Northwestern Switzerland",
                   "grR Ticino", "grR Zurich", "JU", "LU", "NE", "NW", "OW", "SG",
                   "SH", "SO", "SZ", "TG", "TI", "UR", "VD", "VS", "ZG", "ZH")) {
  
  if ("data.frame" %in% class(interval_ends)) {
    if (region_i %in% swissRegions) {
      region_i <- "CHE"
    }

    # in Re estimation, the interval starts on interval_end + 1
    # so the intervention start dates need to be shifted to -1
    interventionDataSubset <- interval_ends %>%
      mutate(shift_date = as_date(ifelse(type == "end", date, date - 1))) %>%
      filter(region == region_i,
             measure != "testing",
             shift_date != "9999-01-01")

    region_interval_ends <- sort(unique(pull(interventionDataSubset, "shift_date")))

  } else {
    region_interval_ends <- interval_ends
  }
  if (length(region_interval_ends) < 1) {
    region_interval_ends <- c(Sys.Date())
  }
  return(region_interval_ends)
}

addCustomIntervalEnds <- function(region_interval_ends,
                                  additional_interval_ends,
                                  region_i,
                                  data_type_i,
                                  swissRegions = c("LIE", "AG", "AI", "AR", "BE", "BL", "BS", "FR", "GE", "GL",
                                                   "GR", "grR Central Switzerland", "grR Eastern Switzerland",
                                                   "grR Espace Mittelland", "grR Lake Geneva Region", "grR Northwestern Switzerland",
                                                   "grR Ticino", "grR Zurich", "JU", "LU", "NE", "NW", "OW", "SG",
                                                   "SH", "SO", "SZ", "TG", "TI", "UR", "VD", "VS", "ZG", "ZH")) {
  
  if (region_i %in% swissRegions) {
    region_i <- "CHE"
  }
  interventionDataSubset <- additional_interval_ends %>%
    filter(region == region_i &
           (data_type == data_type_i | data_type == "all"))
  
  all_interval_ends <- sort(unique(c(region_interval_ends, pull(interventionDataSubset, "date"))))
  return(all_interval_ends)
}



## Perform R(t) estimations with EpiEstim on each 'region' of the data, with each 'method' and on each 'data_type'
## 'region' is the geographical region
## 'data_type' can be 'confirmed' for confirmed cases, 'deaths' for fatalities,
##    'hospitalized' for hospitalization data directly from hospitals (not via openZH here)
doAllReEstimations <- function(
  data,
  slidingWindow = 3,
  methods = c("Cori", "WallingaTeunis"),
  variationTypes = c("step", "slidingWindow"),
  all_delays,
  truncations,
  interval_ends = c("2020-04-01"),
  additional_interval_ends,
  ...) {
  
  results_list <- list()
  
  for (source_i in unique(data$source)) {
    cat("estimating Re for data source: ", source_i, "...\n")
    for (region_i in unique(data$region)) {
      cat("  Region: ", region_i, "\n")

      ## take region specific interval_ends
      region_interval_ends <- getIntervalEnds(interval_ends, region_i, ...)

      ## Run EpiEstim
      for (data_type_i in unique(data$data_type)) {
        subset_data <- data %>% filter(region == region_i & source == source_i & data_type == data_type_i)
        if (nrow(subset_data) == 0) {
          next
        }
        cat("    Data type: ", data_type_i, "\n")

        delay_i <- all_delays[[data_type_i]]
        all_interval_ends <- addCustomIntervalEnds(region_interval_ends,
                                                   additional_interval_ends,
                                                   region_i,
                                                   data_type_i)

        for (replicate_i in unique(unique(subset_data$replicate))) {
          subset_data_rep <- subset(subset_data, subset_data$replicate == replicate_i)
          results_list <- c(results_list,
                            list(
                              doReEstimation(
                                subset_data_rep,
                                slidingWindow = slidingWindow,
                                methods = methods,
                                variationTypes = variationTypes,
                                interval_ends = all_interval_ends,
                                delays = delay_i,
                                truncations = truncations
                              )
                            )
          )
        }
      }
    }
  }
  
  return(bind_rows(results_list))
}

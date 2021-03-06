#' @import ggplot2
#' @import data.table
#' @import matrixStats
#' @importFrom stats median optimize runif
#' @importFrom graphics barplot

#TODO: legend on ggplot in pdf
#TODO: show observed even if only fitting initial to some
#TODO: add excel input for best estimate of hospital data, remove lower.bound.multiplier, upper.bound.multiplier?

GetModelName <- function(dt) {
  dt[, add.name := ""]
  dt[hasE & !hospInf & hospRate, add.name := "(LEMMA)"]
  dt[!hasE & hospInf & !hospRate, add.name := "(COVIDmodel-ish)"]
  model.name <- dt[, paste0(as.integer(hasE), as.integer(hospInf), as.integer(hospRate), add.name)]
  return(model.name)
}

#TRUE if at least required.in.bounds fraction of vector x is in bounds
#if both lower and upper are NA, ignore that bound
#if one of lower/upper is NA but not the other, error
InBounds <- function(x, bounds, required.in.bounds) {
  stopifnot(bounds[xor(is.na(lower), is.na(upper)), .N] == 0)
  if (is.vector(x)) {
    x <- as.matrix(x)
  }
  in.bounds <- x >= bounds$lower & x <= bounds$upper
  return(colMeans(in.bounds, na.rm = T) >= required.in.bounds)
}

RunSim1 <- function(params1, model.inputs, observed.data, internal.args, date.range) {
  if (!internal.args$show.progress) {
    sink("CredibilityInterval progress log.txt")
  }
  sim <- RunSim(total.population = model.inputs$total.population, observed.data = observed.data, start.date = internal.args$simulation.start.date, end.date = model.inputs$end.date, params = params1, search.args = list(max.iter = internal.args$search.max.iter, expander = internal.args$search.expander, num.init.exp = internal.args$search.num.init.exp, max.nonconverge = internal.args$max.nonconverge))
  if (!internal.args$show.progress) {
    sink()
  }
  if (nrow(params1) == 1) {
    sim <- sim[date %in% date.range]
  } else {
    sim <- lapply(sim, function (z) z[as.character(date.range), ])
  }
  return(sim)
}

GetPlotTitle <- function(posterior.niter) {
  if (posterior.niter < 100) {
    warn.str <- "\nVery low number of iterations, DO NOT use for inference"
  } else if (posterior.niter < 1000) {
    warn.str <- "\nLow number of iterations, use with caution"
  } else {
    warn.str <- ""
  }
  paste0("Posterior Distribution, niter = ", posterior.niter, warn.str)
}

GetExcelOutput <- function(sim, best.guess, in.bounds, best.guess.in.bounds, date.range, filestr, all.inputs.str) {
  output.list <- list(hosp = NULL, icu = NULL, vent = NULL, active.cases = NULL, total.cases = NULL)
  output.names <- names(output.list)

  probs2 <- c(0.95, 1, 0.15, 0.25, seq(0.55, 0.9, by = 0.05))
  for (j in output.names) {
    sim.accepted <- sim[[j]][, in.bounds]
    quant1 <- rowQuantiles(sim.accepted, probs = c(0, 0.05, 0.5))
    quant2 <- rowQuantiles(sim.accepted, probs = probs2)
    output <- data.table(date = date.range, quant1, bestguess = best.guess[[j]], quant2)
    output[, notes := ""]
    output[1, notes := GetPlotTitle(posterior.niter = sum(in.bounds))]
    output[2, notes := paste0("bestguess ", ifelse(best.guess.in.bounds, "accepted", "rejected"))]
    output.list[[j]] <- cbind(output.list[[j]], output)
  }
  output.list$all.inputs = all.inputs.str
  filestr.out <- paste0(filestr, ".xlsx")
  openxlsx::write.xlsx(output.list, file = filestr.out)
  cat("\nExcel output: ", filestr.out, "\n")
  return(output.list)
}

GetPdfOutput <- function(hosp, in.bounds, all.params, filestr, bounds.without.multiplier) {
  posterior.title <- GetPlotTitle(posterior.niter = sum(in.bounds))
  filestr.out <- paste0(filestr, ".pdf")
  grDevices::pdf(file = filestr.out)
  dt.plot <- merge(hosp, bounds.without.multiplier, all.x = T, by = "date")
  gg <- ggplot(dt.plot, aes(x=date)) +
    xlab("Date") + 
    ylab("Hospitalizations") +
    geom_ribbon(aes(ymin=`25%`, ymax=`75%`, alpha = "25%-75%")) +
    geom_ribbon(aes(ymin=`15%`, ymax=`85%`, alpha = "15%-85%")) +
    geom_ribbon(aes(ymin=`5%`, ymax=`95%`, alpha = "5%-95%")) +
    geom_line(aes(y = `50%`, color = "Median")) +
    geom_line(aes(y = bestguess, color = "Best Guess")) +
    geom_point(aes(y=upper, shape = "Upper Bound"), fill = "black", na.rm = T) +
    
    geom_point(aes(y=lower, shape = "Lower Bound"), fill = "black", na.rm = T) +
    labs(title = posterior.title, caption = 'Upper Bound and Lower Bound are from "Hospitalization Data" sheet in Excel input') +
    scale_color_manual("Projections", values = c("red", "yellow"), breaks = c("Median", "Best Guess")) +
    scale_alpha_manual("Range", values = c(0.2, 0.3, 0.4), breaks = c("5%-95%", "15%-85%", "25%-75%")) +
    scale_shape_manual("Data", values = c("triangle filled", "triangle down filled"), breaks = c( "Upper Bound", "Lower Bound")) 
  print(gg)

  for (param.name in c("model", "currentRe", names(all.params))) {
    sub <- NULL
    cex.names <- 1

    if (param.name == "model") {
      cur.param <- GetModelName(all.params[, .(hasE = latent.period > 0, hospInf = patients.in.hosp.are.infectious, hospRate = use.hosp.rate)])
      sub <- "(hasE  infect in hosp   rate to hosp)"
      cex.names <- 0.5
    } else if (param.name == "currentRe") {
      cur.param <- all.params[, r0.initial * intervention1.multiplier * intervention2.multiplier] #note: doesn't include int_mult3
    } else {
      cur.param <- all.params[[param.name]]
    }
    param.dt <- data.table(cur.param = factor(cur.param))
    barplot(prop.table(table(param.dt)), main = paste0("Prior Distribution, niter = ", length(in.bounds)), sub = sub, xlab = param.name, ylab = "Freq", cex.names = cex.names)
    barplot(prop.table(table(param.dt[in.bounds])), main = posterior.title, sub = sub, xlab = param.name, ylab = "Freq", cex.names = cex.names)
  }
  grDevices::dev.off()
  cat("\nPDF output: ", filestr.out, "\n")
}

#` Main function to calculate credibility interval
CredibilityInterval <- function(all.params, model.inputs, hosp.bounds, best.guess.params, observed.data, internal.args, extras) {
  options("openxlsx.numFmt" = "0.0")
  sapply(grDevices::dev.list(), grDevices::dev.off) #shuts down any old pdf (if there was a crash part way)
  sapply(seq_len(sink.number()), sink, file=NULL) #same for sink

  all.inputs.str <- utils::capture.output(print(sapply(ls(), function(z) get(z)))) #I'm sure there's a better way to do this
  rm(extras) #extra is only used to save extra information to output file

  date.range <- seq(observed.data[1, date], model.inputs$end.date, by = "day")
  
  bounds.without.multiplier <- merge(data.table(date = date.range), hosp.bounds, all.x = T)
  bounds.with.multiplier <- copy(bounds.without.multiplier)
  bounds.with.multiplier[, lower := internal.args$lower.bound.multiplier * lower]
  bounds.with.multiplier[, upper := internal.args$upper.bound.multiplier * upper]
  
  
  best.guess.sim <- RunSim1(params1 = best.guess.params, model.inputs = model.inputs, observed.data = observed.data, internal.args = internal.args, date.range = date.range)

  best.guess.in.bounds <- InBounds(best.guess.sim$hosp, bounds.with.multiplier, required.in.bounds = internal.args$required.in.bounds)
  if (!best.guess.in.bounds) {
    cat("best.guess$hosp is not compatible with bounds\n")
    dt.print <- cbind(best.guess.sim[, .(best.guess.hosp = round(hosp, 1))], bounds.with.multiplier)
    dt.print[, OK := best.guess.hosp >= lower & best.guess.hosp <= upper]
    print(dt.print[!is.na(lower) & !is.na(upper)])
  }

  sim <- RunSim1(params1 = all.params, model.inputs = model.inputs, observed.data = observed.data, internal.args = internal.args, date.range = date.range)
  in.bounds <- InBounds(sim$hosp, bounds.with.multiplier, required.in.bounds = internal.args$required.in.bounds)

  filestr <- paste0(internal.args$output.filestr, if (internal.args$add.timestamp.to.filestr) date() else "")

  output.list <- GetExcelOutput(sim, best.guess.sim, in.bounds, best.guess.in.bounds, date.range, filestr, all.inputs.str)
  if (sum(in.bounds) <= 1) {
    cat("niter = ", sum(in.bounds), " / ", length(in.bounds), "in bounds. No pdf output written.\n")
  } else {
    GetPdfOutput(hosp = output.list$hosp, in.bounds, all.params, filestr, bounds.without.multiplier)
  }
  return(list(output.list = output.list, best.guess.sim = best.guess.sim, in.bounds = in.bounds, best.guess.in.bounds = best.guess.in.bounds, date.range = date.range, filestr = filestr, all.inputs.str = all.inputs.str))
}



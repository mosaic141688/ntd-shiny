library(raster)
library(sp)
library(leaflet)
library(RANN)
library(rgeos)
#library(geosphere)
library(rjson)
library(httr)
library(wesanderson)
library(readr)
library(stringi)
library(DT)
library(ggplot2)

source("buff_voronoi.R")

# Define map

map <- leaflet(max) %>%
  addTiles("https://cartodb-basemaps-{s}.global.ssl.fastly.net/light_all/{z}/{x}/{y}{r}.png") 

shinyServer(function(input, output){
  
  
  map_data <- reactive({
    
    inFile <- input$File
    inFile_pred <- input$predFile
    if (is.null(inFile))
      return(NULL)
    
    if (is.null(inFile_pred))
      return(NULL)
    
    # Give loading bar
    withProgress(message = 'Hold on',
                 detail = 'Crunching data..',
                 value = 5,
                 {
    
    points<-read.csv(inFile$datapath)
    pred_points <- read.csv(inFile_pred$datapath)
    
      # Prepare input as JSON
      input_data_list <- list(region_definition = list(lng = pred_points$lng,
                                                       lat = pred_points$lat,
                                                       id = pred_points$ID),
                              train_data = list(lng = points$lng,
                                                lat = points$lat,
                                                n_trials = points$Nex,
                                                n_positive = points$Npos),
                              request_parameters = list(threshold = 0.02))

      # Save json
      json_to_post <- toJSON(input_data_list)
      json_to_post <- stri_escape_unicode(json_to_post)
      write(paste0('"', json_to_post, '"'), file="test3.json")

      # Make call to algorithm
      print("Making request")
      request_call <- function(){httr::POST(url = "http://ric70x7.pythonanywhere.com/post",
                                            body = httr::upload_file("test3.json"),
                                            #encode = "json",#this is the path to the json file used as input
                                            httr::content_type("application/json"))}
      request <- request_call()
      print("Got response")
      print(request$status_code)

      # Check it ran. If not, run again.
      if(request$status_code!=200){
        print("Trying again")
        request <- request_call()
        print("Got second response")
      }

      # parse result
      response <- httr::content(request, as='text') # this extracts the response from the request object
      result <<- rjson::fromJSON(response) # this will put the response in a useful format

      # # Plot the result back on the map
      # Poly_list <- list()
      # 
      # for (i in 1:length(result$polygons)){
      #   Poly_list[[i]] <- Polygons(list(Polygon(cbind(result$polygons[[i]]$lng,
      #                                                 result$polygons[[i]]$lat))), i)
      # }
      # sp_Polygons <- SpatialPolygons(Poly_list, 1:length(Poly_list))
      # 
      # # Create sp
      # sp_Polygons <<- SpatialPolygons(Poly_list, 1:length(Poly_list))
      
      # Create buffered polygons
      sp_Polygons <- buff_voronoi_test(data.frame(x = pred_points$lng,
                                             y = pred_points$lat,
                                             id = pred_points$ID), w_buff = 0.3)

      # create spdf
      spdf_data <- data.frame(probability = result$estimates$exceedance_prob,
                              id = result$estimates$id,
                              class = result$estimates$category)
    
    return(list(points = points,
                pred_points = pred_points,
                sp_Polygons = sp_Polygons, spdf_data = spdf_data))
          })
  })
  
  output$pred_table <- DT::renderDT({
    if(is.null(map_data())){
      return(NULL)
    }
    uncertainty <- abs(map_data()$spdf_data$probability - 0.5)
    output_table <- map_data()$spdf_data[order(uncertainty),][1:5,c(2,1)]
    output_table[,2] <- round(output_table[,2], 2)
    names(output_table) <- c("Village ID", "Probability of being a hotspot")
    DT::datatable(output_table, options = list(pageLength = 15), rownames = F)
  })
  
  output$hotspot_table <- DT::renderDT({
    if(is.null(map_data())){
      return(NULL)
    }
    hotspot_index <- which(map_data()$spdf_data$probability >= input$prob_threshold/100)
    hotspot_table <- map_data()$spdf_data[hotspot_index,2:1]
    hotspot_table[,2] <- round(hotspot_table[,2], 2)
    names(hotspot_table) <- c("Village ID", "Probability of being a hotspot")
    DT::datatable(hotspot_table, options = list(pageLength = 10,
                                                columnDefs = list(list(className = 'dt-center',
                                                                       target = 1:2))),
                  rownames = F)
  })
  
  output$hotspot_map <- renderLeaflet({
    
    if(is.null(map_data())){
      return(map %>% setView(0,0,zoom=2))
    }
    
    # Define color palette
    pal <- colorNumeric(wes_palette("Zissou1", 10, type = "continuous")[1:10], seq(0,1,0.01))
    
    labels <- sprintf(
      "<strong>%s</strong><br/>Hotspot probability %g",
      map_data()$spdf_data$id, round(map_data()$spdf_data$probability,3)
    ) %>% lapply(htmltools::HTML)
    
    # Map
    hotspot_class <- ifelse(map_data()$spdf_data$probability >= input$prob_threshold/100,1,0)
    map %>% addPolygons(data=map_data()$sp_Polygons, 
                        color = pal(hotspot_class), 
                        fillOpacity = 0.6, weight = 1,
                        highlightOptions = highlightOptions(
                          weight = 5,
                          color = "#666",
                          bringToFront = TRUE,
                          fillOpacity = 0.7),
                        label = labels
    ) %>%
      
      addCircleMarkers(map_data()$points$lng, map_data()$points$lat, 
                       # popup = paste0("<p><strong>Name: </strong>", map_data()$points$ID,
                       #                                        "<br><strong>Prevalence </strong>",
                       #                                        c(map_data()$points$Npos / map_data()$points$Nex),
                       #                                        "<br><strong>N = </strong>",
                       #                                        map_data()$points$Nex),
                       group = "Survey points", col = "black", radius=2) %>%
      
      addLegend(colors = pal(c(0,1)), labels = c("Not hotspot", "Hotspot")) %>%
      
      addLayersControl(overlayGroups = c("Survey points"), 
                       options = layersControlOptions(collapsed = F))
  })
  
  output$prob_map <- renderLeaflet({
    
    if(is.null(map_data())){
      return(map %>% setView(0,0,zoom=2))
    }

    # Define color palette
    pal <- colorNumeric(wes_palette("Zissou1", 10, type = "continuous")[1:10], seq(0,1,0.01))

    # define uncertainty
    uncertainty <- abs(map_data()$spdf_data$probability - 0.5)
    
    # map
    labels <- sprintf(
      "<strong>%s</strong><br/>Hotspot probability %g",
      map_data()$spdf_data$id, round(map_data()$spdf_data$probability,3)
    ) %>% lapply(htmltools::HTML)

    map %>% addPolygons(data=map_data()$sp_Polygons, 
                        color = pal(map_data()$spdf_data$probability), 
                        fillOpacity = 0.6, weight = 1,
                        highlightOptions = highlightOptions(
                           weight = 5,
                           color = "#666",
                           bringToFront = TRUE,
                           fillOpacity = 0.7),
                         label = labels
                        ) %>%

      addPolygons(data=map_data()$sp_Polygons[order(uncertainty)[1:5],], col = "deeppink", opacity = 1,
                  fillOpacity = 0.1,
                  group = "Villages to sample",
                  highlightOptions = highlightOptions(
                    weight = 5,
                    color = "#666",
                    bringToFront = TRUE,
                    fillOpacity = 0.7),
                  label = labels[order(uncertainty)[1:5]]) %>%
      
      addCircleMarkers(map_data()$points$lng, map_data()$points$lat, 
                       # popup = paste0("<p><strong>Name: </strong>", map_data()$points$ID,
                       #                                        "<br><strong>Prevalence </strong>",
                       #                                        c(map_data()$points$Npos / map_data()$points$Nex),
                       #                                        "<br><strong>N = </strong>",
                       #                                        map_data()$points$Nex),
                       group = "Survey points", col = "black", radius=2) %>%

    addLegend(colors= wes_palette("Zissou1", 10, type = "continuous")[1:10], labels = seq(0.1,1,0.1),
              title = "Hotspot probability") %>%

      addLayersControl(overlayGroups = c("Villages to sample","Survey points"), 
                       options = layersControlOptions(collapsed = F))

                 }) # end loading bar
  
  output$posterior <- renderPlot({
    
    set.seed(1981)
    binom <- density(rbinom(500, 100, 0.05))
    binom <- data.frame(x=binom$x, y=binom$y)
    ggplot(data=binom, aes(x=x, y=y, group=1)) +
      geom_line()
  })
  
  # logos
  output$logo <- renderImage({
    
    # Return a list containing the filename
    list(src = "logo_transparent.png")
  }, deleteFile = FALSE)
  
  #output$Instructions <- textOutput("File with 'lng' and 'lat' columns")
  
  output$EE_logo <- renderImage({
    
    # Return a list containing the filename
    list(src = "GoogleEarthEngine_logo.png")
  }, deleteFile = FALSE)
  
})
